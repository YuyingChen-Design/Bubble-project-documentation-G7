# Bubble software

This is the setup and run guide for Bubble's software. For how the system works and why we designed it this way, see the main README:
- [Software](../README.md#software)
- [Machine Learning](../README.md#machine-learning-1)
- [Debugging Guide](../README.md#debugging-guide)

```
webcam -> combined_osc.py -> 3 Wekinator projects -> combined_reader (Processing) -> Arduino (bubble.ino)
```

## Folder structure

```
software/
├── python/                     camera tracking -> OSC
│   ├── combined_osc.py         main script: one webcam -> head + smile + wave features
│   ├── head_pose_osc.py        head pipeline (also runs on its own)
│   ├── smile_osc.py            smile pipeline (also runs on its own)
│   ├── wave_osc.py             wave pipeline (also runs on its own)
│   ├── wave_config.json        wave feature settings, shared with the Wekinator model
│   ├── face_landmarker.task    MediaPipe face model
│   ├── hand_landmarker.task    MediaPipe hand model
│   └── requirements.txt
├── processing/combined_reader/ main Processing sketch: Wekinator outputs -> one robot command
├── arduino/bubble/             robot firmware: bubble.ino + bubble_movements.h
├── wekinator/                  trained Wekinator projects (head, smile, wave)
└── tests/                      single-pipeline readers, an OSC monitor and a servo calibration sketch
```

Keep every file in `python/` in the same folder. `combined_osc.py` imports the three pipeline scripts. They load the MediaPipe models and `wave_config.json` from the folder they're in.

## Install

| Part | Version we used | What to install |
|---|---|---|
| Python | 3.14 | `pip install -r python/requirements.txt` (mediapipe, opencv-python, numpy, python-osc) |
| Processing | 4.5.7 | The **oscP5** library: Sketch > Import Library > Manage Libraries |
| Arduino IDE | 2.3.10 | The **ServoEasing** library by Armin Joachimsmeyer, from the Library Manager. Set the board to **Arduino Nano Every** |
| Wekinator | *(add version)* | Download from [wekinator.org](http://www.wekinator.org) |

## Running

Start the parts in this order:

1. **Arduino:** open `arduino/bubble/bubble.ino` (it includes `bubble_movements.h` from the same folder) and upload it. Then close the Serial Monitor, because Processing needs the port.
2. **Wekinator:** open the three projects in `wekinator/` and press **Run** in each one. To build your own projects instead, see [Wekinator setup](#wekinator-setup).
3. **Python:**
   ```bash
   python python/combined_osc.py            # asks which camera to use
   python python/combined_osc.py -c 0       # use camera 0 directly
   python python/combined_osc.py --list     # list the available cameras
   ```
   When it starts, look straight ahead for about 1 s so it can set the head neutral. In the camera window, `c` recalibrates the head neutral, and `q` or `Esc` quits.
4. **Processing:** open `processing/combined_reader/combined_reader.pde`. The other `.pde` files open as tabs, and the sketch needs all of them. Then:
   - **Serial port:** in `head.pde`, set `SERIAL_PORT` to your Arduino's port, such as `"COM3"` or `"/dev/cu.usbmodem..."`. Or set it to `""` to use the last port in the list. The available ports are printed when the sketch starts.
   - **No robot:** to test without the robot, set `ROBOT_ENABLED = false` in `combined_reader.pde`.
   - **Recovering:** press `r` to recover the robot from FAULT.

When everything is running, all three panels show "tracking" and the robot line shows `READY`. The first time each OSC address arrives, the Processing console prints a line like `ADDRESS /smile/outputs -> smile`, so you can check that all three Wekinators are connected.

### Other Python options

| Option | What it does |
|---|---|
| `--wave-calibrate [SECONDS]` | Wave calibration (20 s by default), see [Wave calibration](#wave-calibration). Head and smile keep streaming while it runs |
| `--wave-log FILE.csv` | Logs the raw and smoothed wave features to a CSV file |

### Arduino serial commands

The link runs at 115200 baud. The firmware prints `READY` when idle, `BUSY` when it accepts a command and `DONE` when the gesture has finished. Commands that arrive while it is busy are thrown away.

| Command | Movement |
|---|---|
| `N` | Nod |
| `S` | Shake |
| `W` | Cute pose, then wave (waving while smiling) |
| `F` | Disappointed pose, then wave (waving without smiling) |
| `?` | Ping: replies `READY` when idle |

The servo pins (`PIN_R1` … `PIN_HL`) are set at the top of `bubble.ino`. They must match the wiring in [`hardware/`](../hardware/).

## Wekinator setup

The trained projects are in `wekinator/`. To build your own instead, make three projects with these exact settings, because the Processing sketch listens for these message names:

| Project | Listen on port | Inputs | Model type | Outputs (send to localhost:12000) |
|---|---|---|---|---|
| #1 Head | 6448 | 2 | Dynamic Time Warping, 2 gestures | gesture 1 = nod, sent as `/output_1`; gesture 2 = shake, sent as `/output_2` |
| #2 Smile | 6449 | 2 | Classifier, 2 classes | OSC message `/smile/outputs`; class 1 = smiling, class 2 = not smiling |
| #3 Wave | 6450 | 1 | Dynamic Time Warping | OSC message `/wave/outputs` |

Keep the default input message, `/wek/inputs`, for all three. The number of wave inputs is printed when `combined_osc.py` starts. It's 1 unless `use_x` is turned on in `wave_config.json`.

## OSC reference (port 12000)

Everything the Processing sketch receives arrives on port 12000. Each message is routed by its address:

| Address | Sent by | Meaning |
|---|---|---|
| `/output_1`, `/output_2` | Wekinator #1 | Nod / shake detected |
| `/smile/outputs` | Wekinator #2 | Smile class: 1 smiling, 2 not smiling |
| `/wave/outputs` | Wekinator #3 | Wave detected (every message counts as a detection) |
| `/head/status` | Python | 0 calibrating, 1 tracking, 2 holding, 3 lost, 4 recovering |
| `/head/pose` | Python | Pitch, yaw: the same values Wekinator gets (logging) |
| `/smile/status` | Python | 0 starting, 1 tracking, 2 holding, 3 lost, 4 off angle |
| `/smile/features` | Python | mouthSmileLeft, mouthSmileRight (display) |
| `/wave/status` | Python | 0 no hand, 1 tracking, 2 calibrating, 3 reset |
| `/wave/features` | Python | The values sent to Wekinator #3 (display) |
| `/wave/angle` | Python | Hand tilt φ in degrees (display) |

Anything else is logged once as `UNHANDLED`.

## Wave calibration

The wave input is the hand tilt divided by `sigma_phi` from `wave_config.json`. To measure `sigma_phi` for your own camera and hand:

```bash
python python/combined_osc.py --wave-calibrate        # wave normally for 20 s
```

This writes new `sigma_phi` and `sigma_x` values to `wave_config.json`, then exits. It needs at least 30 frames with a hand in view, and leaves the file unchanged if the hand barely moved. **Re-record your Wekinator #3 examples afterwards**, because the input scaling has changed.

## Test sketches

We built and tested each input as its own pipeline before merging them. Each Python script still runs on its own and sends exactly the same messages as `combined_osc.py`, and each one has a small Processing reader. If one gesture stops working, you can test that pipeline alone.

| Test | Run with | What it checks |
|---|---|---|
| `tests/wekinator_reader/` | `python head_pose_osc.py` + Wekinator #1 | Nod/shake detection and the Arduino serial handshake, without smile or wave |
| `tests/smile_reader/` | `python smile_osc.py` + Wekinator #2 | Smile classifier output and smile tracking status |
| `tests/wave_reader/` | `python wave_osc.py` + Wekinator #3 | Wave detections, the hand angle and wave tracking status |
| `tests/test_osc.pde` | anything that sends to port 12000 | An **OSC monitor**: shows every message's address, type tags and values, and whether it streams continuously or arrives as one-off events (e.g. a DTW match) |
| `tests/servo_calibration/` | Arduino, Serial Monitor at 9600 | Type `1 90` to move servo 1 to 90°, or `4 30-80` to sweep servo 4. Used to find each servo's angles |

Only one sketch can listen on port 12000 at a time, so close `combined_reader` before running a test reader.

## Locked conventions

The Wekinator examples were recorded with specific preprocessing settings. These are labelled "LOCKED CONVENTIONS" at the top of each Python file. The recorded examples become invalid, and must be recorded again, if you change any of these:
- the number or order of inputs
- the units
- the send rate
- the filter windows
- the head sign conventions
- `use_x`, `sigma_phi`, `sigma_x`, `w_x`, `mirror` or `send_hz` in `wave_config.json`

`min_hand_size` only filters out small hands. Changing it doesn't need re-recording.
