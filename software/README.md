# Bubble software

How a webcam gesture becomes a robot movement:

```
webcam -> combined_osc.py -> 3 Wekinator projects -> combined_reader (Processing) -> Arduino (bubble.ino)
```

- **Python** (`python/`) tracks your head, smile and hand wave from one webcam and sends the features over OSC.
- **Wekinator** turns those features into gestures: nod or shake, smiling or not smiling, and wave.
- **Processing** (`processing/combined_reader/`) combines the gestures into one interaction and sends a command to the robot over USB serial.
- **Arduino** (`arduino/bubble/`) plays the matching servo movement.

To run everything:

1. Upload the Arduino sketch.
2. Start the three Wekinator projects and set them to run.
3. Start `combined_osc.py`.
4. Start the Processing sketch.

---

## 1. Python: `python/`

Install the dependencies:

```bash
pip install -r requirements.txt
```

Run it:

```bash
python combined_osc.py            # asks which camera to use
python combined_osc.py -c 0       # use camera 0 directly
python combined_osc.py --list     # list the available cameras
```

Keys in the camera window: `c` recalibrates the head neutral, and `q` or `Esc` quits. When it starts, look straight ahead for about a second so it can set the head neutral.

Keep every file in `python/` in the same folder. `combined_osc.py` imports `head_pose_osc.py`, `smile_osc.py` and `wave_osc.py`. It also loads the MediaPipe models (`face_landmarker.task`, `hand_landmarker.task`) and `wave_config.json` from that folder.

### Wave calibration

The values in `wave_config.json` were calibrated to our setup. To calibrate for your own camera and hand:

```bash
python combined_osc.py --wave-calibrate        # wave normally for 20 s
```

This writes new `sigma_phi` and `sigma_x` values to `wave_config.json`, then exits. If you change the config, re-record your Wekinator #3 examples.

### OSC output

| Stream | To Wekinator | Inputs sent to `/wek/inputs` |
|---|---|---|
| Head | port 6448 | 2: pitch, yaw (degrees from neutral) |
| Smile | port 6449 | 2: mouthSmileLeft, mouthSmileRight (0 to 1) |
| Wave | port 6450 | 1: z1 (2 if `use_x` is true in `wave_config.json`) |

It also sends tracking status and features to port 12000 for the Processing sketch: `/head/*`, `/smile/*` and `/wave/*`.

---

## 2. Wekinator

The trained Wekinator projects aren't in this repo, so you need to make three projects and record your own examples. The input counts and output messages must match this table exactly:

| Project | Listen on port | Inputs | Model type | Outputs (send to localhost:12000) |
|---|---|---|---|---|
| #1 Head | 6448 | 2 | Dynamic Time Warping, 2 gestures | gesture 1 = nod, sent as `/output_1`; gesture 2 = shake, sent as `/output_2` |
| #2 Smile | 6449 | 2 | Classifier, 2 classes | OSC message `/smile/outputs`; class 1 = smiling, class 2 = not smiling |
| #3 Wave | 6450 | 1 | Dynamic Time Warping, 1 gesture | OSC message `/wave/outputs` |

Keep the default input message `/wek/inputs` for all three.

---

## 3. Processing: `processing/combined_reader/`

- Install the **oscP5** library from Sketch > Import Library > Manage Libraries.
- Open `combined_reader.pde`. The other `.pde` files in the folder open as tabs, and the sketch needs all of them.
- **Set your Arduino's serial port.** `head.pde` sets `SERIAL_PORT = "COM9";`. Change it to your port, such as `"COM3"` or `"/dev/cu.usbmodem..."`, or set it to `""` to use the last port in the list. The sketch prints the available ports when it starts. Close the Arduino Serial Monitor first, because only one program can open the port.
- **To test without the robot,** set `ROBOT_ENABLED = false` in `combined_reader.pde`.

The sketch listens for OSC on port 12000. The first time each OSC address arrives, the console prints an `ADDRESS ... -> route` line, so you can check that all three Wekinators are connected. Press `r` to recover the robot from FAULT.

---

## 4. Arduino: `arduino/bubble/`

- Board: **Arduino Nano Every**
- Library: **ServoEasing** by Armin Joachimsmeyer, from the Library Manager
- Open `bubble.ino`, which includes `bubble_movements.h` from the same folder.
- The servo pins (`PIN_R1` ... `PIN_HL`) at the top of `bubble.ino` must match your wiring. See `hardware/` in this repo.
- Serial runs at 115200 baud and prints `READY` when it's ready for commands.

Serial commands:

| Command | Movement |
|---|---|
| `N` | Nod |
| `S` | Shake |
| `W` | Wave (smiling) |
| `F` | Wave (not smiling) |
| `?` | Ping (replies `READY` when idle) |
