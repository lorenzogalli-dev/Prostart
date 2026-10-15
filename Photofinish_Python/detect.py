"""Command line: detect the torso crossing the finish line in a race video.

Examples
  python detect.py race.mp4 --line 0.48 --start 4.0
  python detect.py race.mp4 --line 0.54 --line2 0.44 --start 4.0          # angled line
  python detect.py portrait.mp4 --line 0.5 --rotate 90 --method segmentation --show
"""
import argparse
import json
import sys
from pathlib import Path

from finisheye_detection import METHODS, analyze_video, official_hundredths

ROOT = Path(__file__).resolve().parent


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="AI torso finish-line detection")
    p.add_argument("video")
    p.add_argument("--line", type=float, required=True, help="finish line x at the TOP of the frame (0–1)")
    p.add_argument("--line2", type=float, help="finish line x at the BOTTOM (angled line); default vertical")
    p.add_argument("--start", type=float, default=0.0, help="start (gun) time in the video, seconds")
    p.add_argument("--dir", choices=["ltr", "rtl"], default="ltr", help="running direction on screen")
    p.add_argument("--method", choices=METHODS, default="torso")
    p.add_argument("--model", default=str(ROOT / "models" / "pose_landmarker_full.task"))
    p.add_argument("--rotate", type=int, choices=[0, 90, 180, 270], default=0, help="rotate frames clockwise")
    p.add_argument("--min-run", type=float, default=0.0, help="ignore crossings before this many seconds")
    p.add_argument("--show", action="store_true", help="show the analysis while it runs")
    p.add_argument("--save-frame", help="save the finish frame with overlay (e.g. finish.jpg)")
    p.add_argument("--json", action="store_true", help="print the result as JSON")
    a = p.parse_args(argv)

    if not Path(a.model).exists():
        p.error(f"model not found: {a.model}\n  run: python tools/download_models.py")
    line = a.line if a.line2 is None else (a.line, a.line2)
    r = analyze_video(a.video, a.model, line, start_s=a.start, direction=-1 if a.dir == "rtl" else 1,
                      method=a.method, rotate=a.rotate, min_run_s=a.min_run, show=a.show,
                      save_frame=a.save_frame)
    out = {
        "video": a.video, "method": a.method, "line": line, "start_s": a.start, "rotate": a.rotate,
        "frames": r.frames, "detections": r.detections,
        "time_s": None if r.crossing is None else round(r.seconds("t"), 4),
        "official_s": None if r.crossing is None else official_hundredths(r.seconds("t")),
        "interpolated_s": None if r.crossing is None else round(r.seconds("interpolated"), 4),
        "first_frame_s": None if r.crossing is None else round(r.seconds("first_frame_t"), 4),
        "uncertainty_ms": None if r.crossing is None else round(r.crossing.uncertainty_ms, 1),
        "timing": None if r.crossing is None else r.crossing.method,
    }
    if a.json:
        print(json.dumps(out, indent=2))
    elif r.crossing is None:
        print(f"No crossing detected ({r.detections}/{r.frames} frames with a torso).")
    else:
        print(f"Finish: {out['time_s']:.3f} s after the start   (official, rounded up: {out['official_s']:.2f} s)")
        print(f"  interpolated {out['interpolated_s']:.3f} s | first frame past line {out['first_frame_s']:.3f} s"
              f" | ±{out['uncertainty_ms']} ms | {a.method}, {r.detections}/{r.frames} frames")
    return 0 if r.crossing else 1


if __name__ == "__main__":
    sys.exit(main())
