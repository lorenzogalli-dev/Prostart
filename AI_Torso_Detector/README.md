# finisheye-detection

AI detection of the **torso crossing the finish line** in sprint videos, with sub-frame timing.
Built on Google MediaPipe Pose Landmarker; this is the detection core of the FinishEye
sprint-timing project (phone app + start / reaction-time system).

## What it does

1. **Finds the torso** in every frame with MediaPipe Pose (33 body landmarks).
2. **Picks the torso point** with one of four methods (below).
3. **Measures its distance past the finish line** — the line may be **angled**; its position is
   taken at the torso point's own height.
4. **Times the crossing** three ways: the first frame past the line, linear interpolation between
   the two frames around the line, and a straight-line fit over ±160 ms that averages out jitter.

## Detection methods

| `--method` | torso point | notes |
|---|---|---|
| `torso` *(default)* | centre of both shoulders and both hips (landmarks 11, 12, 23, 24) | steadiest point; lies mid-body, so it crosses later than the chest front |
| `shoulders` | midpoint of the shoulders (11, 12) | |
| `segmentation` | **chest front** from the body silhouette; arms removed using elbow/wrist landmarks | closest to the athletics rule (torso front) |
| `landmarks` | frontmost shoulder/hip joint + chest depth | no silhouette, faster |

### Results on a real side-view clip

Sprinter filmed side-on at 25 fps; true chest-front crossing measured from the pixels: **0.867 s**
after the start mark.

| method | first frame past line | interpolated | **fitted** | error |
|---|---|---|---|---|
| `torso` | 0.960 s | 0.934 s | **0.930 s** | +63 ms |
| `shoulders` | 0.920 s | 0.897 s | **0.895 s** | +28 ms |
| `segmentation` | 0.840 s | 0.838 s | **0.858 s** | −9 ms |

## Install

```bash
pip install -r requirements.txt
```
```bash
python tools/download_models.py
```

MediaPipe is pinned to 0.10.14 (newer 1.x Windows builds can be blocked by Windows Smart App Control).

## Use

```bash
python detect.py race.mp4 --line 0.48 --start 4.0
```

| option | meaning |
|---|---|
| `--line X` | finish line x at the top of the frame, as a fraction of the width (0 = left, 1 = right) |
| `--line2 X` | x at the bottom → **angled line** (omit for a vertical line) |
| `--start S` | time of the start (gun) in the video, seconds — results are relative to it |
| `--dir ltr/rtl` | running direction on screen |
| `--method` | `torso`, `shoulders`, `segmentation`, `landmarks` |
| `--rotate 90` | rotate frames clockwise (videos filmed in portrait) |
| `--show` | watch the analysis live · `--save-frame finish.jpg` saves the finish frame · `--json` |

As a library:

```python
from finisheye_detection import analyze_video

r = analyze_video("race.mp4", "models/pose_landmarker_full.task",
                  line=(0.54, 0.44), start_s=4.0, method="segmentation")
print(r.seconds())                 # fitted time after the start (s)
print(r.seconds("first_frame_t"))  # first frame past the line
```

Lower level: `TorsoDetector(...).detect(frame, t_ms)` → `Detection(x, y, …)`, and
`FinishJudge(line).push(t_ms, x, y)` → `Crossing`, then `.refine()`.

## Filming tips

- Put the camera **on the extension of the finish line**, looking along it, **level**, at 50–60 fps
  or more, in good light (motion blur hurts every method).
- **Angled line** (`--line2`): use it when the camera is **tilted** (not level). If the camera is
  simply off to the side, the painted line looks slanted only through perspective — then give a
  vertical line through the painted line **where the runner's feet land** instead.

## Tests

```bash
python -m unittest discover -s tests -v
```

## Layout

```
finisheye_detection/
  detector.py   MediaPipe pose → torso point (4 methods)
  judge.py      crossing detection, interpolation, line fit, angled line, rounding
  video.py      video analysis loop, rotation, overlay drawing
detect.py       command-line tool
tools/download_models.py
tests/test_detection.py
```
