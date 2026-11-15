"""Webcam smile features (MediaPipe blendshapes) -> second Wekinator classifier via OSC.

Runs alongside head_pose_osc.py (same webcam, separate Wekinator instance).

OSC out:
  -> Wekinator #2  127.0.0.1:6449  /wek/inputs <mouthSmileLeft> <mouthSmileRight>
  -> smile_reader  127.0.0.1:12000 /smile/status <int>          (heartbeat, every tick)
                                   /smile/features <L> <R>      (same values, logging only)

Keys:  q / Esc = quit

Pipeline per camera frame:
  MediaPipe blendshapes -> [mouthSmileLeft, mouthSmileRight] (looked up by NAME)
  -> validity check (face present, head not turned too far)
  -> median filter (spike rejection) -> shared target
A sender thread streams the target at a fixed SEND_HZ.

Tracking validity (/smile/status codes):
  0 STARTING   no valid face seen yet (nothing sent to Wekinator)
  1 TRACKING   features are live
  2 HOLDING    face lost < LOSS_HOLD_S ago, last values held
  3 LOST       face lost longer than LOSS_HOLD_S, last values still held
  4 OFF_ANGLE  face visible but turned beyond MAX_YAW/MAX_PITCH: blendshapes unreliable
While not TRACKING the last valid values keep streaming (steady timing for Wekinator);
the reader must use /smile/status to decide whether to trust the classifier.

LOCKED CONVENTIONS (smile v1) - changing any invalidates recorded Wekinator examples:
  * 2 inputs, in order: FEATURE_NAMES
  * units: raw MediaPipe blendshape score 0..1, no calibration, no threshold
  * send rate SEND_HZ, median window MEDIAN_WINDOW

Structured for merging with head_pose_osc.py later: SmileExtractor works on a
FaceLandmarker result that also contains the pose matrix, and SmileStreamer is
self-contained, so one camera loop can feed both pipelines.
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

# ---- ports / addresses ----
WEK_IP, WEK_PORT = "127.0.0.1", 6449          # second Wekinator (head pose uses 6448)
WEK_ADDRESS = "/wek/inputs"
READER_IP, READER_PORT = "127.0.0.1", 12000   # Processing reader (shared port, own addresses)
STATUS_ADDRESS = "/smile/status"
FEATURES_ADDRESS = "/smile/features"

# ---- locked conventions: do not change without re-recording examples ----
FEATURE_NAMES = ("mouthSmileLeft", "mouthSmileRight")
SEND_HZ = 20
MEDIAN_WINDOW = 5
# -------------------------------------------------------------------------

SEND_PERIOD = 1.0 / SEND_HZ
LOSS_HOLD_S = 0.5        # HOLDING -> LOST after this long without a face
MAX_YAW_DEG = 35.0       # beyond this (absolute, camera-relative) blendshapes are unreliable
MAX_PITCH_DEG = 30.0

STARTING, TRACKING, HOLDING, LOST, OFF_ANGLE = 0, 1, 2, 3, 4
STATUS_TEXT = {STARTING: "starting", TRACKING: "tracking", HOLDING: "no face - holding",
               LOST: "no face - lost", OFF_ANGLE: "face turned too far"}

MAX_CAMERAS = 5
CAM_BACKEND = cv2.CAP_DSHOW if sys.platform == "win32" else cv2.CAP_ANY
MODEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "face_landmarker.task")


def pitch_yaw_from_matrix(m):
    """(pitch, yaw) in degrees from MediaPipe's 4x4 facial transformation matrix.
    Same maths as head_pose_osc.py; used here only for the off-angle validity check."""
    r = np.array(m, dtype=np.float64).reshape(4, 4)[:3, :3]
    r = r / np.linalg.norm(r, axis=0)
    yaw = math.atan2(r[0, 2], r[2, 2])
    pitch = math.asin(max(-1.0, min(1.0, -r[1, 2])))
    return math.degrees(pitch), math.degrees(yaw)


class SmileExtractor:
    """Turns one FaceLandmarker result into validated, median-filtered smile features.

    update(result) -> (features or None, status). features is a 2-element list in
    FEATURE_NAMES order when status is TRACKING, else None.
    Needs the landmarker created with output_face_blendshapes=True and
    output_facial_transformation_matrixes=True.
    """

    def __init__(self):
        self.history = deque(maxlen=MEDIAN_WINDOW)

    def reset(self):
        self.history.clear()

    def update(self, result):
        if not result.face_blendshapes:
            self.reset()                  # never median across a gap
            return None, None             # caller decides HOLDING / LOST
        if result.facial_transformation_matrixes:
            pitch, yaw = pitch_yaw_from_matrix(result.facial_transformation_matrixes[0])
            if abs(yaw) > MAX_YAW_DEG or abs(pitch) > MAX_PITCH_DEG:
                self.reset()
                return None, OFF_ANGLE
        scores = {c.category_name: c.score for c in result.face_blendshapes[0]}
        try:
            raw = [float(scores[name]) for name in FEATURE_NAMES]   # fixed order, by name
        except KeyError:
            self.reset()
            return None, None
        self.history.append(raw)
        return np.median(self.history, axis=0).tolist(), TRACKING


class SmileStreamer(threading.Thread):
    """Streams the latest features to Wekinator and status/features to the reader at SEND_HZ."""

    def __init__(self, wek_client, reader_client):
        super().__init__(daemon=True)
        self.wek = wek_client
        self.reader = reader_client
        self.lock = threading.Lock()
        self.stop_evt = threading.Event()
        self.features = None          # None until the first valid frame
        self.status = STARTING

    def update(self, features=None, status=None):
        with self.lock:
            if features is not None:
                self.features = [float(v) for v in features]
            if status is not None:
                self.status = status

    def run(self):
        nxt = time.monotonic()
        while not self.stop_evt.is_set():
            nxt += SEND_PERIOD
            with self.lock:
                feats = None if self.features is None else list(self.features)
                status = self.status
            if feats is not None:
                self.wek.send_message(WEK_ADDRESS, feats)
                self.reader.send_message(FEATURES_ADDRESS, feats)
            self.reader.send_message(STATUS_ADDRESS, int(status))   # heartbeat
            delay = nxt - time.monotonic()
            if delay > 0:
                self.stop_evt.wait(delay)
            else:
                nxt = time.monotonic()

    def stop(self):
        self.stop_evt.set()


def find_cameras():
    found = []
    for i in range(MAX_CAMERAS):
        cap = cv2.VideoCapture(i, CAM_BACKEND)
        if cap.isOpened() and cap.read()[0]:
            found.append((i, int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
                          int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))))
        cap.release()
    return found


def choose_camera(cameras):
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
    ap = argparse.ArgumentParser(description="Webcam smile blendshapes -> Wekinator via OSC.")
    ap.add_argument("-c", "--camera", type=int, help="camera index to use (skips the picker)")
    ap.add_argument("-l", "--list", action="store_true", help="list available cameras and exit")
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
        output_face_blendshapes=True,
        output_facial_transformation_matrixes=True,   # for the off-angle check
    )
    landmarker = vision.FaceLandmarker.create_from_options(options)
    extractor = SmileExtractor()
    streamer = SmileStreamer(SimpleUDPClient(WEK_IP, WEK_PORT),
                             SimpleUDPClient(READER_IP, READER_PORT))
    streamer.start()

    cap = cv2.VideoCapture(camera_index, CAM_BACKEND)
    if not cap.isOpened() or not cap.read()[0]:
        streamer.stop()
        raise SystemExit(f"Could not open camera {camera_index} (in use by another app?). "
                         f"See what's available with: python smile_osc.py --list")
    print(f"Using camera {camera_index}")
    print(f"Smile v1: {list(FEATURE_NAMES)} raw 0..1, {SEND_HZ} Hz, median {MEDIAN_WINDOW} "
          f"-> Wekinator :{WEK_PORT}, status -> :{READER_PORT}")

    seen_face = False
    lost_since = None
    t0 = time.monotonic()

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        now = time.monotonic()
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        result = landmarker.detect_for_video(image, int((now - t0) * 1000))

        features, status = extractor.update(result)
        if status == TRACKING:
            seen_face, lost_since = True, None
            streamer.update(features=features, status=TRACKING)
            text = f"smile L {features[0]:.2f}  R {features[1]:.2f}"
        else:
            if status is None:                        # no face
                if lost_since is None:
                    lost_since = now
                status = HOLDING if now - lost_since <= LOSS_HOLD_S else LOST
            else:                                     # OFF_ANGLE: face present
                lost_since = None
            if not seen_face:
                status = STARTING
            streamer.update(status=status)            # keep last valid features
            text = STATUS_TEXT[status]

        cv2.putText(frame, text, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
        cv2.imshow(f"smile -> OSC :{WEK_PORT}  (q=quit)", frame)
        if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
            break

    streamer.stop()
    cap.release()
    cv2.destroyAllWindows()
    landmarker.close()


if __name__ == "__main__":
    main()
