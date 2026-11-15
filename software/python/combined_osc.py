"""One webcam -> head pose (Wekinator #1) + smile (Wekinator #2) + hand wave (Wekinator #3).

Replaces running head_pose_osc.py, smile_osc.py and wave_osc.py side by side.
The camera is opened ONCE; every captured frame goes to both the face pipeline
(one FaceLandmarker shared by head + smile) and the hand pipeline (HandLandmarker).
Each pipeline behaves exactly as in its own script.

OSC out (unchanged from the separate scripts):cc
  head  -> Wekinator #1  :6448   /wek/inputs <pitch> <yaw>
           reader        :12000  /head/status <int>   /head/pose <pitch> <yaw>
  smile -> Wekinator #2  :6449   /wek/inputs <mouthSmileLeft> <mouthSmileRight>
           reader        :12000  /smile/status <int>  /smile/features <L> <R>
  wave  -> Wekinator #3  :6450   /wek/inputs <z1> [<z2>]   (only while a hand is tracked)
           reader        :12000  /wave/status <int>   /wave/features ...  /wave/angle <deg>

Face features stream continuously; the wave never gates the face detector.

Keys (camera window):  c = recalibrate head neutral   q / Esc = quit
Options: -c/--camera, -l/--list, --wave-calibrate [SECONDS], --wave-log CSV
  --wave-calibrate: wave_osc.py's calibration. Head + smile keep streaming; only the
  wave stream pauses. Writes sigma_phi/sigma_x to wave_config.json and exits when done.

Conventions, ports, senders, config and filters are imported from head_pose_osc.py,
smile_osc.py and wave_osc.py, so recorded Wekinator examples stay valid.
Change them there, not here.
"""
import argparse
import csv
import math
import os
import time
from collections import deque

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision
from pythonosc.udp_client import SimpleUDPClient

import head_pose_osc as hp
import smile_osc as sm
import wave_osc as wv


class HeadPipeline:
    """head_pose_osc.py's per-frame logic: calibration, median, neutral subtraction,
    EMA + deadzone (hp.PostFilter, settings in head_pose_osc.py), loss hold/neutral, slew."""

    def __init__(self):
        self.sender = hp.FixedRateSender(SimpleUDPClient(hp.OSC_IP, hp.OSC_PORT),
                                         SimpleUDPClient(hp.STATUS_IP, hp.STATUS_PORT))
        self.neutral = np.zeros(2)
        self.history = deque(maxlen=hp.MEDIAN_WINDOW)
        self.post = hp.PostFilter()
        self.recalibrate(announce=False)

    def start(self):
        self.sender.start()

    def stop(self):
        self.sender.stop()

    def recalibrate(self, announce=True):
        self.calibrating, self.calib_samples = True, []
        self.history.clear()
        self.post.reset()
        self.lost_since, self.went_neutral = None, False
        self.sender.pause()
        if announce:
            print("HEAD: recalibrating - look straight ahead and hold still")

    def update(self, result, now):
        """Process one frame's result. Returns the overlay text."""
        if result.facial_transformation_matrixes:
            reacquired = self.lost_since is not None
            if reacquired:
                self.history.clear()
                self.post.reset()
            self.lost_since, self.went_neutral = None, False

            self.history.append(hp.pitch_yaw_from_matrix(result.facial_transformation_matrixes[0]))
            pitch, yaw = np.median(self.history, axis=0)

            if self.calibrating:
                self.calib_samples.append((pitch, yaw))
                if len(self.calib_samples) >= hp.CALIB_FRAMES:
                    self.neutral = np.mean(self.calib_samples, axis=0)
                    self.calibrating = False
                    self.sender.start_streaming()
                    print(f"HEAD: neutral set: pitch={self.neutral[0]:.1f} yaw={self.neutral[1]:.1f}")
                return f"head: calibrating {len(self.calib_samples)}/{hp.CALIB_FRAMES}"
            p = hp.PITCH_SIGN * (pitch - self.neutral[0])
            y = hp.YAW_SIGN * (yaw - self.neutral[1])
            p, y = self.post([p, y])          # EMA, then deadzone (as head_pose_osc.py)
            self.sender.update([p, y], ease=reacquired)
            self.sender.set_status(hp.TRACKING)
            return f"head: pitch {p:+6.1f}  yaw {y:+6.1f}"

        if self.calibrating:
            return "head: calibrating - no face"
        if self.lost_since is None:
            self.lost_since = now
        if now - self.lost_since > hp.LOSS_HOLD_S and not self.went_neutral:
            self.sender.update([0.0, 0.0], ease=True)
            self.went_neutral = True
        self.sender.set_status(hp.LOST if self.went_neutral else hp.HOLDING)
        return "head: no face - neutral" if self.went_neutral else "head: no face - holding"


class SmilePipeline:
    """smile_osc.py's per-frame logic: validated median features + status."""

    def __init__(self):
        self.extractor = sm.SmileExtractor()
        self.streamer = sm.SmileStreamer(SimpleUDPClient(sm.WEK_IP, sm.WEK_PORT),
                                         SimpleUDPClient(sm.READER_IP, sm.READER_PORT))
        self.seen_face = False
        self.lost_since = None

    def start(self):
        self.streamer.start()

    def stop(self):
        self.streamer.stop()

    def update(self, result, now):
        features, status = self.extractor.update(result)
        if status == sm.TRACKING:
            self.seen_face, self.lost_since = True, None
            self.streamer.update(features=features, status=sm.TRACKING)
            return f"smile: L {features[0]:.2f}  R {features[1]:.2f}"
        if status is None:                       # no face
            if self.lost_since is None:
                self.lost_since = now
            status = sm.HOLDING if now - self.lost_since <= sm.LOSS_HOLD_S else sm.LOST
        else:                                    # OFF_ANGLE: face present
            self.lost_since = None
        if not self.seen_face:
            status = sm.STARTING
        self.streamer.update(status=status)
        return "smile: " + sm.STATUS_TEXT[status]


class WavePipeline:
    """wave_osc.py's per-frame logic (hand choice, resets, calibration, CSV logging),
    fed frames from the shared camera instead of its own capture loop."""

    def __init__(self, calibrate_s=None, log_path=None):
        self.cfg = wv.load_config()
        self.calibrate_s = calibrate_s
        self.calibrating = calibrate_s is not None
        self.landmarker = vision.HandLandmarker.create_from_options(vision.HandLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=wv.MODEL),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=2,          # so the largest / tracked one can be chosen
        ))
        self.extractor = wv.WaveExtractor(self.cfg)
        self.streamer = wv.WaveStreamer(self.cfg, SimpleUDPClient(wv.WEK_IP, wv.WEK_PORT),
                                        SimpleUDPClient(wv.READER_IP, wv.READER_PORT))
        self.calib_phi, self.calib_x = [], []
        self.had_hand = False
        self.last_size_print = -1e9
        self.done = False         # calibration finished
        self.t0 = None

        self.csv_file = self.writer = None
        csv_path = None
        if self.calibrating:
            csv_path = os.path.join(wv.HERE, time.strftime("wave_calibration_%Y%m%d_%H%M%S.csv"))
        elif log_path:
            csv_path = log_path
        if csv_path:
            self.csv_file = open(csv_path, "w", newline="")
            self.writer = csv.writer(self.csv_file)
            self.writer.writerow(["t", "phi_raw", "phi_smooth", "x_raw", "x_smooth"])
            print(f"WAVE: logging to {csv_path}")

    def print_startup(self, W, H):
        cfg = self.cfg
        names = "[z1=phi/sigma_phi" + (", z2=w_x*x~/sigma_x]" if cfg["use_x"] else "]")
        print(f"WAVE  : {wv.n_features(cfg)} float(s) per message {names} -> Wekinator :{wv.WEK_PORT} "
              f"at {cfg['send_hz']} Hz. Set Wekinator #3 to {wv.n_features(cfg)} input(s).")
        print(f"        sigma_phi={cfg['sigma_phi']} sigma_x={cfg['sigma_x']} w_x={cfg['w_x']} "
              f"mirror={cfg['mirror']} one_euro={cfg['one_euro']} (frame {W}x{H}, aspect {W / H:.3f})")
        if self.calibrating:
            print(f"WAVE CALIBRATION: wave normally for {self.calibrate_s:.0f} s "
                  f"(nothing is sent to Wekinator #3; head + smile keep streaming)")

    def start(self, t0):
        self.t0 = t0
        if self.calibrating:
            self.streamer.set_calibrating()
        self.streamer.start()

    def stop(self):
        self.streamer.stop()
        self.landmarker.close()
        if self.csv_file:
            self.csv_file.close()
        if self.calibrating:
            wv.finish_calibration(self.cfg, wv.CONFIG_PATH, self.calib_phi, self.calib_x)

    def hand_frame(self, frame):
        """The frame the hand pipeline sees: mirrored before MediaPipe iff config says so."""
        return cv2.flip(frame, 1) if self.cfg["mirror"] else frame

    def update(self, frame, now):
        """frame = hand_frame(...). Returns (feat, status_text, extra) for wv.draw_overlay."""
        H, W = frame.shape[:2]                        # actual size, never hard-coded
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        result = self.landmarker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb),
                                                  int((now - self.t0) * 1000))
        feat = self.extractor.update(result, W, H, now)
        for ev in feat["events"]:
            print(f"WAVE: reset ({ev})")
            if not self.calibrating:
                self.streamer.mark_reset()
        if now - self.last_size_print >= 1.0 and feat["hands"]:
            self.last_size_print = now
            print("WAVE: hand sizes " + ", ".join(
                f"{s:.3f}{' (tracked)' if tr else '' if ok else ' (<min)'}" for s, _, tr, ok in feat["hands"]))
        if not feat["valid"]:
            if self.had_hand:
                print("WAVE: hand lost")
            self.had_hand = False
            if not self.calibrating:
                self.streamer.lost()
            status_text = "no hand - not sending" if not feat["hands"] else "hands below min_hand_size - not sending"
        else:
            self.had_hand = True
            if self.writer:
                self.writer.writerow([f"{now - self.t0:.4f}", feat["phi"], feat["phi_s"], feat["x"], feat["x_s"]])
            if self.calibrating:
                self.calib_phi.append(feat["phi"])
                self.calib_x.append(feat["x"])
                status_text = f"calibrating {now - self.t0:4.1f}/{self.calibrate_s:.0f} s"
            else:
                self.streamer.update(feat["z"], math.degrees(feat["phi_s"]), now)
                status_text = "z = " + "  ".join(f"{v:+.2f}" for v in feat["z"])
        extra = None
        if self.calibrating:
            extra = f"CALIBRATING - wave! {max(0, self.calibrate_s - (now - self.t0)):.0f} s left"
            if now - self.t0 >= self.calibrate_s:
                self.done = True
        return feat, status_text, extra


def parse_args():
    ap = argparse.ArgumentParser(description="Webcam head pose + smile + hand wave -> three Wekinators via OSC.")
    ap.add_argument("-c", "--camera", type=int, help="camera index to use (skips the picker)")
    ap.add_argument("-l", "--list", action="store_true", help="list available cameras and exit")
    ap.add_argument("--wave-calibrate", type=float, nargs="?", const=20.0, metavar="SECONDS",
                    help="wave calibration for SECONDS (default 20): writes sigma_phi/sigma_x to "
                         "wave_config.json, then exits. Head + smile keep streaming meanwhile")
    ap.add_argument("--wave-log", metavar="CSV", help="log raw vs smoothed wave features to CSV")
    return ap.parse_args()


def main():
    args = parse_args()
    if args.list or args.camera is None:
        print("Looking for cameras...")
        cameras = hp.find_cameras()
        if not cameras:
            raise SystemExit("No cameras found. Is the USB webcam plugged in?")
        if args.list:
            for i, w, h in cameras:
                print(f"  [{i}] {w}x{h}")
            return
        camera_index = hp.choose_camera(cameras)
    else:
        camera_index = args.camera

    # one landmarker producing everything both pipelines need
    landmarker = vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=hp.MODEL),
        running_mode=vision.RunningMode.VIDEO,
        num_faces=1,
        output_facial_transformation_matrixes=True,   # head pose + smile off-angle check
        output_face_blendshapes=True,                 # smile
    ))

    # the ONE capture for all pipelines
    cap = cv2.VideoCapture(camera_index, hp.CAM_BACKEND)
    ok, first = cap.read() if cap.isOpened() else (False, None)
    if not ok:
        raise SystemExit(f"Could not open camera {camera_index} (in use by another app?). "
                         f"See what's available with: python combined_osc.py --list")
    H0, W0 = first.shape[:2]
    print(f"Using camera {camera_index}, {W0}x{H0}")
    print(f"HEAD  v1: [pitch, yaw] deg, signs=({hp.PITCH_SIGN:+.0f},{hp.YAW_SIGN:+.0f}), "
          f"{hp.SEND_HZ} Hz, median {hp.MEDIAN_WINDOW} -> Wekinator :{hp.OSC_PORT}")
    print(f"        post-filters: EMA {'alpha=' + str(hp.EMA_ALPHA) if hp.USE_EMA else 'off'}, "
          f"deadzone {'+-' + str(hp.DEADZONE_DEG) + ' deg' if hp.USE_DEADZONE else 'off'}")
    print(f"SMILE v1: {list(sm.FEATURE_NAMES)} raw 0..1, {sm.SEND_HZ} Hz, "
          f"median {sm.MEDIAN_WINDOW} -> Wekinator :{sm.WEK_PORT}")

    head, smile = HeadPipeline(), SmilePipeline()
    wave = WavePipeline(args.wave_calibrate, args.wave_log)
    wave.print_startup(W0, H0)
    print("Look straight ahead to calibrate the head neutral.")
    head.start()
    smile.start()
    t0 = time.monotonic()
    wave.start(t0)

    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            now = time.monotonic()

            # face pipelines: unmirrored frame, exactly as in head_pose_osc.py / smile_osc.py
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            result = landmarker.detect_for_video(image, int((now - t0) * 1000))
            head_text = head.update(result, now)
            smile_text = smile.update(result, now)

            # hand pipeline: same captured frame (mirrored first only if wave_config says so)
            hand_frame = wave.hand_frame(frame)
            feat, wave_text, wave_extra = wave.update(hand_frame, now)

            # one preview window: wave overlay at the top (as in wave_osc.py),
            # head + smile lines at the bottom
            view = hand_frame
            wv.draw_overlay(view, feat, wave.cfg, "wave: " + wave_text, wave_extra)
            Hv = view.shape[0]
            cv2.putText(view, head_text, (10, Hv - 45), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
            cv2.putText(view, smile_text, (10, Hv - 15), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 200, 255), 2)
            cv2.imshow("head + smile + wave -> OSC  (c=calibrate head, q=quit)", view)
            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if key == ord("c"):
                head.recalibrate()
            if wave.done:
                print("WAVE CALIBRATION finished - exiting (as wave_osc.py --calibrate does)")
                break
    finally:
        head.stop()
        smile.stop()
        wave.stop()          # also writes the calibration result when calibrating
        cap.release()
        cv2.destroyAllWindows()
        landmarker.close()


if __name__ == "__main__":
    main()
