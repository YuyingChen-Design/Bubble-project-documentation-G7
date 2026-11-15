"""Webcam head pose (pitch/yaw) via MediaPipe -> OSC on port 6448.

Keys:  c = recalibrate neutral (look straight ahead, hold still)   q / Esc = quit
OSC:   /wek/inputs <pitch deg> <yaw deg>   (neutral-relative, Wekinator on port 6448)

Pipeline per camera frame:
  MediaPipe pose matrix -> pitch/yaw -> median filter (spike rejection)
  -> subtract session neutral -> EMA (USE_EMA) -> deadzone (USE_DEADZONE) -> shared target
  (combined_osc.py applies the same EMA + deadzone, using the settings below.)
A separate sender thread streams the target at a fixed SEND_HZ, so Wekinator/DTW
always sees evenly spaced samples regardless of camera frame rate.

Tracking loss: the last value is held for LOSS_HOLD_S, then the output eases to
neutral (0, 0). On re-acquisition (and after recalibration) the output is
slew-limited so the jump back never looks like a nod or shake.

Status heartbeat: every send tick, /head/status <int> goes to the Processing
sketch on port 12000 (0 calibrating, 1 tracking, 2 holding, 3 lost, 4 recovering)
so it can refuse gestures detected while the measurements were not real.

LOCKED CONVENTIONS (v1) - changing any of these invalidates recorded Wekinator
examples; re-record every gesture if you touch them:
  * 2 inputs, in order: [pitch, yaw]
  * units: degrees, relative to the session neutral pose
  * signs: PITCH_SIGN / YAW_SIGN below
  * send rate: SEND_HZ, median window: MEDIAN_WINDOW

NOTE: don't name this file mediapipe.py - it would shadow the real package.
"""
import argparse
import math
import os
import sys
import threading
import time
from collections import deque

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision
from pythonosc.udp_client import SimpleUDPClient

OSC_IP, OSC_PORT = "127.0.0.1", 6448
# Tracking status/heartbeat goes straight to the Processing sketch (bypasses Wekinator).
STATUS_IP, STATUS_PORT = "127.0.0.1", 12000
MAX_CAMERAS = 5   # indices probed when listing cameras
CAM_BACKEND = cv2.CAP_DSHOW if sys.platform == "win32" else cv2.CAP_ANY  # DirectShow: faster USB cams on Windows

# /head/status <int> codes - keep in sync with wekinator_reader.pde
CALIBRATING, TRACKING, HOLDING, LOST, RECOVERING = 0, 1, 2, 3, 4
CALIB_FRAMES = 30

# ---- locked conventions: do not change without re-recording gestures ----
PITCH_SIGN, YAW_SIGN = 1.0, 1.0
SEND_HZ = 20                # fixed output rate
MEDIAN_WINDOW = 5           # frames; odd. Rejects isolated bad frames.
# -------------------------------------------------------------------------

# ---- post-filters (also used by combined_osc.py's HeadPipeline - change them here) ----
# Applied in order AFTER the median filter and neutral subtraction, per axis:
#   EMA      : y = EMA_ALPHA * x + (1 - EMA_ALPHA) * y_prev   (per camera frame)
#   deadzone : |y| < DEADZONE_DEG  ->  0   (values outside are passed through unchanged)
# Changing these changes what Wekinator sees: re-record examples after toggling/tuning.
USE_EMA = True
EMA_ALPHA = 0.4
USE_DEADZONE = True
DEADZONE_DEG = 5.0
# ------------------------------------------------------------------------------------------

SEND_PERIOD = 1.0 / SEND_HZ
LOSS_HOLD_S = 0.5           # hold last value this long after the face disappears
RECOVER_STEP_DEG = 3.0      # max change per send tick while recovering (60 deg/s at 20 Hz)
MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "face_landmarker.task")


def pitch_yaw_from_matrix(m):
    """Extract (pitch, yaw) in degrees from MediaPipe's 4x4 facial transformation matrix."""
    r = np.array(m, dtype=np.float64).reshape(4, 4)[:3, :3]
    r = r / np.linalg.norm(r, axis=0)  # strip scale so it's a pure rotation
    yaw = math.atan2(r[0, 2], r[2, 2])
    pitch = math.asin(max(-1.0, min(1.0, -r[1, 2])))
    return math.degrees(pitch), math.degrees(yaw)


class PostFilter:
    """EMA smoothing then deadzone, on neutral-relative [pitch, yaw]. reset() starts fresh."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.ema = None

    def __call__(self, v):
        v = np.asarray(v, dtype=float)
        if USE_EMA:
            self.ema = v.copy() if self.ema is None else EMA_ALPHA * v + (1.0 - EMA_ALPHA) * self.ema
            v = self.ema
        if USE_DEADZONE:
            v = np.where(np.abs(v) < DEADZONE_DEG, 0.0, v)
        return v


class FixedRateSender(threading.Thread):
    """Sends the latest target at exactly SEND_HZ. Slew-limits when easing is requested."""

    def __init__(self, client, status_client):
        super().__init__(daemon=True)
        self.client = client
        self.status_client = status_client
        self.lock = threading.Lock()
        self.stop_evt = threading.Event()
        self.target = np.zeros(2)
        self.out = np.zeros(2)
        self.active = False   # nothing is sent until calibration finishes
        self.slew = False
        self.status = CALIBRATING

    def set_status(self, status):
        with self.lock:
            self.status = status

    def pause(self):
        with self.lock:
            self.active = False
            self.status = CALIBRATING

    def start_streaming(self):
        """Begin (or resume) streaming from neutral after calibration."""
        with self.lock:
            self.target = np.zeros(2)
            self.out = np.zeros(2)
            self.slew = False
            self.active = True
            self.status = TRACKING

    def update(self, target, ease=False):
        with self.lock:
            self.target = np.asarray(target, dtype=float)
            if ease:
                self.slew = True

    def run(self):
        nxt = time.monotonic()
        while not self.stop_evt.is_set():
            nxt += SEND_PERIOD
            msg = None
            with self.lock:
                if self.active:
                    if self.slew:
                        self.out = self.out + np.clip(self.target - self.out,
                                                      -RECOVER_STEP_DEG, RECOVER_STEP_DEG)
                        if np.allclose(self.out, self.target, atol=0.05):
                            self.slew = False
                    else:
                        self.out = self.target.copy()
                    msg = [float(self.out[0]), float(self.out[1])]
                # a "tracking" sample that is still being slew-limited is not real data yet
                status = RECOVERING if (self.status == TRACKING and self.slew) else self.status
            if msg is not None:
                # Wekinator only listens on /wek/inputs, all inputs in one message
                self.client.send_message("/wek/inputs", msg)
                # same values to Processing, for logging only
                self.status_client.send_message("/head/pose", msg)
            # heartbeat: sent every tick, even while calibrating
            self.status_client.send_message("/head/status", int(status))
            delay = nxt - time.monotonic()
            if delay > 0:
                self.stop_evt.wait(delay)
            else:
                nxt = time.monotonic()  # fell behind; don't burst to catch up

    def stop(self):
        self.stop_evt.set()


def find_cameras():
    """Return [(index, width, height)] for every camera that delivers a frame."""
    found = []
    for i in range(MAX_CAMERAS):
        cap = cv2.VideoCapture(i, CAM_BACKEND)
        if cap.isOpened() and cap.read()[0]:
            found.append((i, int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
                          int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))))
        cap.release()
    return found


def choose_camera(cameras):
    """Interactive picker. Returns a camera index."""
    if len(cameras) == 1:
        print(f"Only one camera found, using {cameras[0][0]}")
        return cameras[0][0]
    print("Cameras found (0 is usually the built-in laptop camera):")
    for i, w, h in cameras:
        print(f"  [{i}] {w}x{h}")
    valid = {i for i, _, _ in cameras}
    while True:
        choice = input("Pick a camera index: ").strip()
        if choice.isdigit() and int(choice) in valid:
            return int(choice)
        print(f"  not one of {sorted(valid)}")


def parse_args():
    ap = argparse.ArgumentParser(description="Webcam head pose (pitch/yaw) -> Wekinator via OSC.")
    ap.add_argument("-c", "--camera", type=int,
                    help="camera index to use (skips the picker)")
    ap.add_argument("-l", "--list", action="store_true",
                    help="list available cameras and exit")
    return ap.parse_args()


def main():
    args = parse_args()
    if args.list or args.camera is None:
        print("Looking for cameras...")
        cameras = find_cameras()
        if not cameras:
            raise SystemExit("No cameras found. Is the USB webcam plugged in?")
        if args.list:
            for i, w, h in cameras:
                print(f"  [{i}] {w}x{h}")
            return
        camera_index = choose_camera(cameras)
    else:
        camera_index = args.camera

    options = vision.FaceLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=MODEL),
        running_mode=vision.RunningMode.VIDEO,
        num_faces=1,
        output_facial_transformation_matrixes=True,
    )
    landmarker = vision.FaceLandmarker.create_from_options(options)
    sender = FixedRateSender(SimpleUDPClient(OSC_IP, OSC_PORT),
                             SimpleUDPClient(STATUS_IP, STATUS_PORT))
    sender.start()

    cap = cv2.VideoCapture(camera_index, CAM_BACKEND)
    if not cap.isOpened() or not cap.read()[0]:
        sender.stop()
        raise SystemExit(f"Could not open camera {camera_index}. "
                         f"See what's available with: python head_pose_osc.py --list")
    print(f"Using camera {camera_index}")

    neutral = np.zeros(2)
    calib_samples = []
    calibrating = True
    history = deque(maxlen=MEDIAN_WINDOW)
    post = PostFilter()      # EMA + deadzone, after neutral subtraction
    lost_since = None        # time the face was last seen, None while tracking
    went_neutral = False     # already eased to neutral for this loss
    t0 = time.monotonic()

    print(f"Conventions v1: [pitch, yaw] deg, signs=({PITCH_SIGN:+.0f},{YAW_SIGN:+.0f}), "
          f"{SEND_HZ} Hz, median {MEDIAN_WINDOW}. Look straight ahead to calibrate.")
    print(f"Post-filters: EMA {'alpha=' + str(EMA_ALPHA) if USE_EMA else 'off'}, "
          f"deadzone {'+-' + str(DEADZONE_DEG) + ' deg' if USE_DEADZONE else 'off'} "
          f"(experimental - re-record Wekinator examples)")

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        now = time.monotonic()
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        result = landmarker.detect_for_video(image, int((now - t0) * 1000))

        status = "no face"
        if result.facial_transformation_matrixes:
            reacquired = lost_since is not None
            if reacquired:
                history.clear()  # don't median across the gap
                post.reset()     # don't smooth across the gap either
            lost_since, went_neutral = None, False

            history.append(pitch_yaw_from_matrix(result.facial_transformation_matrixes[0]))
            pitch, yaw = np.median(history, axis=0)

            if calibrating:
                calib_samples.append((pitch, yaw))
                status = f"calibrating {len(calib_samples)}/{CALIB_FRAMES}"
                if len(calib_samples) >= CALIB_FRAMES:
                    neutral = np.mean(calib_samples, axis=0)
                    calibrating = False
                    sender.start_streaming()
                    print(f"Neutral set: pitch={neutral[0]:.1f} yaw={neutral[1]:.1f}")
            else:
                p = PITCH_SIGN * (pitch - neutral[0])
                y = YAW_SIGN * (yaw - neutral[1])
                p, y = post([p, y])          # EMA, then deadzone
                sender.update([p, y], ease=reacquired)
                sender.set_status(TRACKING)
                status = f"pitch {p:+6.1f}  yaw {y:+6.1f}"
        elif not calibrating:
            if lost_since is None:
                lost_since = now
            held = now - lost_since
            if held > LOSS_HOLD_S and not went_neutral:
                sender.update([0.0, 0.0], ease=True)   # glide back to neutral
                went_neutral = True
            sender.set_status(LOST if went_neutral else HOLDING)
            status = "no face - holding" if not went_neutral else "no face - neutral"

        cv2.putText(frame, status, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
        cv2.imshow("head pose -> OSC :6448  (c=calibrate, q=quit)", frame)
        key = cv2.waitKey(1) & 0xFF
        if key in (ord("q"), 27):
            break
        if key == ord("c"):
            calibrating, calib_samples = True, []
            history.clear()
            post.reset()
            lost_since, went_neutral = None, False
            sender.pause()

    sender.stop()
    cap.release()
    cv2.destroyAllWindows()
    landmarker.close()


if __name__ == "__main__":
    main()
