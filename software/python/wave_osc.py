"""Webcam hand-wave features (MediaPipe HandLandmarker) -> Wekinator #3 (DTW) via OSC.

OSC out:
  -> Wekinator #3  127.0.0.1:6450   /wek/inputs <z1> [<z2>]    (only while a hand is tracked)
  -> wave_reader   127.0.0.1:12000  /wave/status <int>         (heartbeat, every tick)
                                    /wave/features <z1> [<z2>] (same values as Wekinator, logging)
                                    /wave/angle <phi deg>      (debug)
Keys:  q / Esc = quit

Hand choice: the LARGEST hand with palm size >= min_hand_size (closest to the camera
= the user), then the same hand is followed frame to frame by palm position.
Handedness scores are not used (they rate left-vs-right, not "is this a hand").

Features (per frame):
  1. Aspect fix   q_i = (x_i * W/H, y_i), W/H read from each frame at runtime
  2. phi          u = q9 - q0, phi = atan2(u_x, -u_y)  [rad; upright 0, image-right > 0]
                  measured against the camera vertical, so wrist and elbow waves look the same;
                  unwrapped against the previous frame, so it never jumps by 2*pi
  3. x~ (optional, use_x)  palm centre c = mean(q0,q5,q9,q13,q17),
                  size s = (|q9-q0| + |q5-q17|) / 2, slow EMA m of c_x (tau),
                  x~ = (c_x - m) / s
  4. One Euro filter per feature, real dt
  5. Fixed scaling z1 = phi/sigma_phi, z2 = w_x * x~/sigma_x  (from wave_config.json)
A timer thread sends the latest smoothed values at send_hz. When no hand is
tracked nothing goes to Wekinator (no zeros: they'd draw fake shapes for DTW).
History (filters, EMA, unwrapping) is reset on acquisition, when the tracked hand
changes, and after a gap between hand frames longer than max_gap_s.

Status codes (/wave/status): 0 NO_HAND, 1 TRACKING, 2 CALIBRATING (not sending),
  3 RESET (history just restarted; held RESET_HOLD_S so the reader restarts its settle timer)

Calibration:  python wave_osc.py --calibrate 20
  Records raw phi and x~ to CSV while you wave, writes their standard deviations
  to sigma_phi / sigma_x in wave_config.json. Re-record Wekinator examples after.

LOCKED CONVENTIONS - wave_config.json is the contract with Wekinator. Changing
use_x, sigma_*, w_x, mirror or send_hz invalidates recorded examples. The number
of floats per message is printed at startup and must equal Wekinator's input count.

Structured for merging into combined_osc.py: WaveExtractor works on one
HandLandmarker result plus the frame size; WaveStreamer is self-contained.
"""
import argparse
import csv
import json
import math
import os
import threading
import time

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision
from pythonosc.udp_client import SimpleUDPClient

import head_pose_osc as hp   # camera picker + backend, shared with the other scripts

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "hand_landmarker.task")
CONFIG_PATH = os.path.join(HERE, "wave_config.json")

# ---- ports / addresses ----
WEK_IP, WEK_PORT = "127.0.0.1", 6450          # third Wekinator (head 6448, smile 6449)
WEK_ADDRESS = "/wek/inputs"
READER_IP, READER_PORT = "127.0.0.1", 12000
STATUS_ADDRESS = "/wave/status"
FEATURES_ADDRESS = "/wave/features"
ANGLE_ADDRESS = "/wave/angle"

NO_HAND, TRACKING, CALIBRATING, RESET = 0, 1, 2, 3
STALE_S = 0.2              # a "tracked" hand older than this is treated as gone
RESET_HOLD_S = 0.1         # RESET status is held at least this long so the reader can't miss it

DEFAULT_CONFIG = {
    "use_x": False,        # feature 2 (relative palm position) on/off
    "sigma_phi": 0.4,      # rad
    "sigma_x": 0.8,
    "w_x": 0.5,
    "tau_s": 1.0,          # EMA time constant for the x~ baseline
    # Hands with palm size s below this are ignored. s is in frame heights: a hand at
    # arm's length is ~0.1+. Set it between your size at demo distance and the crowd's
    # (both shown on the overlay). Gating only - not a feature, no re-recording needed.
    "min_hand_size": 0.05,
    "max_gap_s": 0.25,     # time between hand frames above this resets the filters
    "switch_radius": 1.5,  # tracked hand may move this many hand sizes per frame and stay "the same hand"
    "send_hz": 30,
    "mirror": False,       # flip the frame BEFORE MediaPipe (and for display). Keep fixed.
    "one_euro": {"min_cutoff": 1.0, "beta": 0.5, "d_cutoff": 1.0},
}

WRIST, INDEX_MCP, MIDDLE_MCP, RING_MCP, PINKY_MCP = 0, 5, 9, 13, 17


# ================= config =================

def load_config(path=CONFIG_PATH):
    """Load wave_config.json, filling missing keys with defaults (and writing the file if new)."""
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if os.path.exists(path):
        with open(path) as f:
            user = json.load(f)
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    else:
        save_config(cfg, path)
        print(f"Wrote default config {path}")
    return cfg


def save_config(cfg, path=CONFIG_PATH):
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)


def n_features(cfg):
    return 2 if cfg["use_x"] else 1


# ================= filters =================

class OneEuro:
    """One Euro filter (Casiez et al. 2012) using the real dt of each sample."""

    def __init__(self, min_cutoff, beta, d_cutoff):
        self.min_cutoff, self.beta, self.d_cutoff = min_cutoff, beta, d_cutoff
        self.reset()

    def reset(self):
        self.x_prev = None
        self.dx_prev = 0.0

    @staticmethod
    def _alpha(cutoff, dt):
        tau = 1.0 / (2.0 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def __call__(self, x, dt):
        if self.x_prev is None or dt <= 0:
            self.x_prev, self.dx_prev = x, 0.0
            return x
        dx = (x - self.x_prev) / dt
        a_d = self._alpha(self.d_cutoff, dt)
        dx_hat = a_d * dx + (1 - a_d) * self.dx_prev
        cutoff = self.min_cutoff + self.beta * abs(dx_hat)
        a = self._alpha(cutoff, dt)
        x_hat = a * x + (1 - a) * self.x_prev
        self.x_prev, self.dx_prev = x_hat, dx_hat
        return x_hat


# ================= features =================

PALM = [WRIST, INDEX_MCP, MIDDLE_MCP, RING_MCP, PINKY_MCP]


def wrap_pi(a):
    """Wrap an angle to [-pi, pi)."""
    return (a + math.pi) % (2.0 * math.pi) - math.pi


def measure_hand(lm, W, H):
    """Aspect-corrected landmarks, palm size s (frame heights) and palm centre for one hand."""
    k = W / H                                     # aspect correction factor
    q = np.array([[p.x * k, p.y] for p in lm])   # 21 x 2, same units on both axes
    s = (np.linalg.norm(q[MIDDLE_MCP] - q[WRIST]) + np.linalg.norm(q[INDEX_MCP] - q[PINKY_MCP])) / 2.0
    c = q[PALM].mean(axis=0)
    return q, float(s), c


class WaveExtractor:
    """Turns one HandLandmarker result into raw + smoothed wave features.

    Hand choice: on acquisition the LARGEST hand above min_hand_size (closest to the
    camera = the user). After that the same hand is followed frame to frame by palm
    position; if it can't be found within switch_radius hand sizes, the largest hand
    is taken again and everything is reset.

    History is reset (filters, EMA baseline, phi unwrapping) when the hand is
    acquired, when the tracked hand changes, and after a gap longer than max_gap_s.

    update(result, W, H, t) -> dict, always with:
      "valid"  : True if features were produced this frame
      "events" : list of reset reasons this frame ("acquired", "hand changed", "gap ...")
      "hands"  : [(s, centre_px, tracked, big_enough)] for every detected hand (overlay)
    and when valid also "phi", "x", "phi_s", "x_s", "z", "s", "wrist_px", "knuckle_px".
    """

    def __init__(self, cfg):
        self.cfg = cfg
        oe = cfg["one_euro"]
        self.f_phi = OneEuro(oe["min_cutoff"], oe["beta"], oe["d_cutoff"])
        self.f_x = OneEuro(oe["min_cutoff"], oe["beta"], oe["d_cutoff"])
        self.track_c = None     # palm centre of the tracked hand (aspect-corrected)
        self.track_s = None
        self.reset()

    def reset(self):
        """Clear all history. The tracked-hand identity is kept (see forget_hand)."""
        self.f_phi.reset()
        self.f_x.reset()
        self.m = None           # EMA baseline of c_x
        self.t_prev = None
        self.phi_prev = None    # last unwrapped phi

    def forget_hand(self):
        self.track_c = self.track_s = None
        self.reset()

    def _choose(self, cands):
        """Pick the tracked hand among (index, q, s, c) candidates. Returns (cand, event or None)."""
        if self.track_c is not None:
            dists = [np.linalg.norm(c - self.track_c) for _, _, _, c in cands]
            j = int(np.argmin(dists))
            if dists[j] <= self.cfg["switch_radius"] * self.track_s:
                return cands[j], None
            largest = max(cands, key=lambda h: h[2])
            return largest, "hand changed"
        return max(cands, key=lambda h: h[2]), "acquired"

    def update(self, result, W, H, t):
        events, hands, cands = [], [], []
        for i, lm in enumerate(result.hand_landmarks or []):
            q, s, c = measure_hand(lm, W, H)
            ok = s >= self.cfg["min_hand_size"]
            hands.append([s, (int(c[0] / (W / H) * W), int(c[1] * H)), False, ok])
            if ok:
                cands.append((i, q, s, c))
        if not cands:                                 # no (big enough) hand
            self.forget_hand()
            return {"valid": False, "events": events, "hands": hands}

        (i, q, s, c), ev = self._choose(cands)
        if ev:
            events.append(ev)
            self.reset()
        if self.t_prev is not None and t - self.t_prev > self.cfg["max_gap_s"]:
            events.append(f"gap {1000 * (t - self.t_prev):.0f} ms")
            self.reset()
        self.track_c, self.track_s = c, s
        hands[i][2] = True

        dt = 0.0 if self.t_prev is None else t - self.t_prev
        self.t_prev = t

        # feature 1: tilt from the camera vertical, unwrapped so it never jumps by 2*pi
        u = q[MIDDLE_MCP] - q[WRIST]
        phi_raw = math.atan2(u[0], -u[1])
        phi = phi_raw if self.phi_prev is None else self.phi_prev + wrap_pi(phi_raw - self.phi_prev)
        self.phi_prev = phi

        # feature 2: palm x relative to a slow baseline, in hand sizes
        c_x = float(c[0])
        if self.m is None:
            self.m = c_x
        else:
            alpha = 1.0 - math.exp(-dt / self.cfg["tau_s"]) if dt > 0 else 0.0
            self.m += alpha * (c_x - self.m)
        x_t = (c_x - self.m) / s

        phi_s = self.f_phi(phi, dt)
        x_s = self.f_x(x_t, dt)

        z = [phi_s / self.cfg["sigma_phi"]]
        if self.cfg["use_x"]:
            z.append(self.cfg["w_x"] * x_s / self.cfg["sigma_x"])

        lm = result.hand_landmarks[i]
        return {"valid": True, "events": events, "hands": hands,
                "phi": phi, "x": x_t, "phi_s": phi_s, "x_s": x_s, "z": z, "s": s,
                "wrist_px": (int(lm[WRIST].x * W), int(lm[WRIST].y * H)),
                "knuckle_px": (int(lm[MIDDLE_MCP].x * W), int(lm[MIDDLE_MCP].y * H))}


# ================= sending =================

class WaveStreamer(threading.Thread):
    """Sends the latest smoothed features at a fixed rate from a timer, never from the frame loop."""

    def __init__(self, cfg, wek_client, reader_client):
        super().__init__(daemon=True)
        self.period = 1.0 / cfg["send_hz"]
        self.wek, self.reader = wek_client, reader_client
        self.lock = threading.Lock()
        self.stop_evt = threading.Event()
        self.z = None
        self.phi_deg = 0.0
        self.t_valid = -1e9
        self.status = NO_HAND
        self.reset_until = -1e9

    def mark_reset(self):
        """Extractor history was reset: report RESET briefly so the reader restarts its settle timer."""
        with self.lock:
            self.reset_until = time.monotonic() + RESET_HOLD_S

    def update(self, z, phi_deg, t):
        with self.lock:
            self.z, self.phi_deg, self.t_valid, self.status = list(z), phi_deg, t, TRACKING

    def lost(self):
        with self.lock:
            self.z, self.status = None, NO_HAND

    def set_calibrating(self):
        with self.lock:
            self.z, self.status = None, CALIBRATING

    def run(self):
        nxt = time.monotonic()
        while not self.stop_evt.is_set():
            nxt += self.period
            with self.lock:
                status = self.status
                fresh = self.z is not None and time.monotonic() - self.t_valid <= STALE_S
                z = list(self.z) if fresh else None
                phi_deg = self.phi_deg
                resetting = time.monotonic() < self.reset_until
            if status == TRACKING and not fresh:
                status = NO_HAND                     # camera stalled: don't repeat old data
            elif status == TRACKING and resetting:
                status = RESET                       # data flows, but history just restarted
            if z is not None:
                self.wek.send_message(WEK_ADDRESS, z)
                self.reader.send_message(FEATURES_ADDRESS, z)
                self.reader.send_message(ANGLE_ADDRESS, float(phi_deg))
            self.reader.send_message(STATUS_ADDRESS, int(status))   # heartbeat
            delay = nxt - time.monotonic()
            if delay > 0:
                self.stop_evt.wait(delay)
            else:
                nxt = time.monotonic()

    def stop(self):
        self.stop_evt.set()


# ================= overlay =================

def draw_overlay(frame, feat, cfg, status_text, extra=None):
    # every detected hand with its size s: yellow = tracked, white = candidate, grey = below min_hand_size
    for s, (px, py), tracked, ok in feat["hands"]:
        col = (0, 255, 255) if tracked else (255, 255, 255) if ok else (130, 130, 130)
        label = f"s={s:.3f}" + ("" if ok else " <min")
        cv2.putText(frame, label, (px - 40, py + 30), cv2.FONT_HERSHEY_SIMPLEX, 0.6, col, 2)
    if feat["valid"]:
        cv2.line(frame, feat["wrist_px"], feat["knuckle_px"], (0, 255, 255), 3)
        cv2.circle(frame, feat["wrist_px"], 5, (0, 0, 255), -1)
        cv2.circle(frame, feat["knuckle_px"], 5, (0, 255, 0), -1)
        line = f"phi {math.degrees(feat['phi_s']):+6.1f} deg  (raw {math.degrees(feat['phi']):+6.1f})"
        if cfg["use_x"]:
            line += f"   x~ {feat['x_s']:+5.2f}"
        cv2.putText(frame, line, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
    cv2.putText(frame, status_text, (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
    if extra:
        cv2.putText(frame, extra, (10, 90), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 200, 255), 2)


# ================= main =================

def parse_args():
    ap = argparse.ArgumentParser(description="Webcam hand-wave features -> Wekinator (DTW) via OSC.")
    ap.add_argument("-c", "--camera", type=int, help="camera index to use (skips the picker)")
    ap.add_argument("-l", "--list", action="store_true", help="list available cameras and exit")
    ap.add_argument("--calibrate", type=float, nargs="?", const=20.0, metavar="SECONDS",
                    help="wave for SECONDS (default 20), write sigma_phi/sigma_x to the config")
    ap.add_argument("--log", metavar="CSV", help="log raw vs smoothed features to CSV during normal use")
    ap.add_argument("--config", default=CONFIG_PATH, help="config file (default wave_config.json)")
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

    cfg = load_config(args.config)
    calibrating = args.calibrate is not None

    landmarker = vision.HandLandmarker.create_from_options(vision.HandLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=MODEL),
        running_mode=vision.RunningMode.VIDEO,
        num_hands=2,          # so the most confident one can be chosen
    ))
    extractor = WaveExtractor(cfg)
    streamer = WaveStreamer(cfg, SimpleUDPClient(WEK_IP, WEK_PORT),
                            SimpleUDPClient(READER_IP, READER_PORT))

    cap = cv2.VideoCapture(camera_index, hp.CAM_BACKEND)
    ok, frame = cap.read() if cap.isOpened() else (False, None)
    if not ok:
        raise SystemExit(f"Could not open camera {camera_index} (in use by another app?). "
                         f"See what's available with: python wave_osc.py --list")
    H, W = frame.shape[:2]
    print(f"Using camera {camera_index}, {W}x{H} (aspect {W / H:.3f})")
    names = "[z1=phi/sigma_phi" + (", z2=w_x*x~/sigma_x]" if cfg["use_x"] else "]")
    print(f"WAVE: {n_features(cfg)} float(s) per message {names} -> Wekinator :{WEK_PORT} "
          f"at {cfg['send_hz']} Hz. Set Wekinator #3 to {n_features(cfg)} input(s).")
    print(f"      sigma_phi={cfg['sigma_phi']} sigma_x={cfg['sigma_x']} w_x={cfg['w_x']} "
          f"mirror={cfg['mirror']} one_euro={cfg['one_euro']}")

    # CSV: calibration or --log
    csv_file = writer = None
    csv_path = None
    if calibrating:
        csv_path = os.path.join(HERE, time.strftime("wave_calibration_%Y%m%d_%H%M%S.csv"))
    elif args.log:
        csv_path = args.log
    if csv_path:
        csv_file = open(csv_path, "w", newline="")
        writer = csv.writer(csv_file)
        writer.writerow(["t", "phi_raw", "phi_smooth", "x_raw", "x_smooth"])
        print(f"Logging to {csv_path}")
    if calibrating:
        streamer.set_calibrating()
        print(f"CALIBRATION: wave normally for {args.calibrate:.0f} s (nothing is sent to Wekinator)")

    streamer.start()
    t0 = time.monotonic()
    calib_phi, calib_x = [], []
    had_hand = False
    last_size_print = -1e9

    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            if cfg["mirror"]:
                frame = cv2.flip(frame, 1)            # before MediaPipe, every frame
            H, W = frame.shape[:2]                    # actual size, never hard-coded
            now = time.monotonic()
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            result = landmarker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb),
                                                 int((now - t0) * 1000))

            feat = extractor.update(result, W, H, now)
            for ev in feat["events"]:
                print(f"WAVE: reset ({ev})")
                if not calibrating:
                    streamer.mark_reset()
            if now - last_size_print >= 1.0 and feat["hands"]:
                last_size_print = now
                print("WAVE: hand sizes " + ", ".join(
                    f"{s:.3f}{' (tracked)' if tr else '' if ok else ' (<min)'}" for s, _, tr, ok in feat["hands"]))
            if not feat["valid"]:                     # no (big enough) hand
                if had_hand:
                    print("WAVE: hand lost")
                had_hand = False
                if not calibrating:
                    streamer.lost()
                status_text = "no hand - not sending" if not feat["hands"] else "hands below min_hand_size - not sending"
            else:
                had_hand = True
                if writer:
                    writer.writerow([f"{now - t0:.4f}", feat["phi"], feat["phi_s"], feat["x"], feat["x_s"]])
                if calibrating:
                    calib_phi.append(feat["phi"])
                    calib_x.append(feat["x"])
                    status_text = f"calibrating {now - t0:4.1f}/{args.calibrate:.0f} s"
                else:
                    streamer.update(feat["z"], math.degrees(feat["phi_s"]), now)
                    status_text = "z = " + "  ".join(f"{v:+.2f}" for v in feat["z"])

            extra = f"CALIBRATING - wave! {max(0, args.calibrate - (now - t0)):.0f} s left" if calibrating else None
            draw_overlay(frame, feat, cfg, status_text, extra)
            cv2.imshow(f"wave -> OSC :{WEK_PORT}  (q=quit)", frame)
            if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
                break
            if calibrating and now - t0 >= args.calibrate:
                break
    finally:
        streamer.stop()
        cap.release()
        cv2.destroyAllWindows()
        landmarker.close()
        if csv_file:
            csv_file.close()

    if calibrating:
        finish_calibration(cfg, args.config, calib_phi, calib_x)


def finish_calibration(cfg, path, phis, xs):
    if len(phis) < 30:
        print(f"CALIBRATION FAILED: only {len(phis)} hand frames recorded. Config unchanged.")
        return
    sd_phi, sd_x = float(np.std(phis)), float(np.std(xs))
    print(f"CALIBRATION: {len(phis)} frames, std(phi)={sd_phi:.4f} rad "
          f"({math.degrees(sd_phi):.1f} deg), std(x~)={sd_x:.4f}")
    if sd_phi < 1e-3:
        print("CALIBRATION FAILED: phi barely moved - did you wave? Config unchanged.")
        return
    cfg["sigma_phi"] = round(sd_phi, 4)
    if sd_x >= 1e-3:
        cfg["sigma_x"] = round(sd_x, 4)
    else:
        print("  x~ barely moved; sigma_x left unchanged")
    save_config(cfg, path)
    print(f"CALIBRATION: wrote sigma_phi={cfg['sigma_phi']} sigma_x={cfg['sigma_x']} to {path}")
    print("  Scaling changed: re-record your Wekinator wave examples.")


if __name__ == "__main__":
    main()
