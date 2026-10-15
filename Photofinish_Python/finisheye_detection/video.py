"""Analyse a race video: detector + judge, frame by frame."""
from __future__ import annotations

from dataclasses import dataclass

import cv2

from .detector import Detection, TorsoDetector
from .judge import Crossing, FinishJudge, line_at

_ROTATE = {90: cv2.ROTATE_90_CLOCKWISE, 180: cv2.ROTATE_180, 270: cv2.ROTATE_90_COUNTERCLOCKWISE}


def rotate_frame(frame, degrees: int):
    """Rotate clockwise (e.g. 90 for videos filmed in portrait)."""
    code = _ROTATE.get(int(degrees) % 360)
    return frame if code is None else cv2.rotate(frame, code)


@dataclass
class Result:
    crossing: Crossing | None
    t_start_ms: float
    fps: float
    frames: int
    detections: int

    def seconds(self, which: str = "t") -> float | None:
        """Time after the start mark in seconds: 't' (fitted), 'interpolated' or 'first_frame_t'."""
        return None if self.crossing is None else (getattr(self.crossing, which) - self.t_start_ms) / 1000


def analyze_video(path: str, model_path: str, line, start_s: float = 0.0, direction: int = 1,
                  method: str = "torso", rotate: int = 0, analysis_width: int = 640,
                  min_run_s: float = 0.0, post_roll_s: float = 1.0, max_run_s: float = 60.0,
                  show: bool = False, save_frame: str | None = None) -> Result:
    """Run the detection on a video file.

    line       x fraction (vertical line) or (x at top, x at bottom) for an angled line
    start_s    time of the start (gun) in the video; results are relative to it
    direction  +1 athlete runs left→right on screen, −1 right→left
    show       display the frames with the torso point and line while analysing (q = stop)
    save_frame write the frame nearest the crossing with overlay to this image path
    """
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise FileNotFoundError(f"cannot open video {path}")
    # CAP_PROP_FPS is only a nominal rate. On iPhone slow-motion files it is
    # wrong (196.47 for a 240 fps clip, 2026-10-15), and index / fps made every
    # time 22 % too long. Times are read per frame from CAP_PROP_POS_MSEC
    # instead (photofinish2.py did this), and the start is sought by time.
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    t_start = start_s * 1000
    judge = FinishJudge(line=line, direction=direction, t_start=t_start, min_run_ms=min_run_s * 1000)
    if start_s > 0:
        cap.set(cv2.CAP_PROP_POS_MSEC, t_start)
    idx, n_det = 0, 0
    first_t = last_t = None
    frames_near: list[tuple[float, object, Detection | None]] = []
    keep = int(fps * (post_roll_s + 0.5)) + 5   # enough frames to still hold the crossing frame

    with TorsoDetector(model_path, method=method) as det:
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            t = cap.get(cv2.CAP_PROP_POS_MSEC)  # this frame's own timestamp, ms
            idx += 1
            first_t = t if first_t is None else first_t
            last_t = t
            frame = rotate_frame(frame, rotate)
            small = cv2.resize(frame, (analysis_width, int(frame.shape[0] * analysis_width / frame.shape[1])),
                               interpolation=cv2.INTER_AREA)
            d = det.detect(small, t, direction)
            if d is not None:
                n_det += 1
                judge.push(t, d.x, d.y)
            if save_frame or show:
                frames_near.append((t, small, d))
                del frames_near[:-keep]        # recent frames, for the evidence image
            if show:
                view = draw(small.copy(), d, judge.line, direction)
                cv2.imshow("finisheye-detection", view)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break
            c = judge.crossing
            if c and t > c.interpolated + post_roll_s * 1000:
                break
            if t - t_start > max_run_s * 1000:
                break
    cap.release()
    if show:
        cv2.destroyAllWindows()

    crossing = judge.refine()
    if save_frame and crossing and frames_near:
        t, img, d = min(frames_near, key=lambda f: abs(f[0] - crossing.t))
        cv2.imwrite(save_frame, draw(img.copy(), d, judge.line, direction))
    if first_t is not None and last_t is not None and last_t > first_t and idx > 1:
        fps = (idx - 1) / ((last_t - first_t) / 1000)   # the rate really in the file
    return Result(crossing, t_start, fps, idx, n_det)


def draw(img, d: Detection | None, line, direction: int = 1):
    """Overlay: red finish line, torso outline, dot (yellow before / green after the line)."""
    h, w = img.shape[:2]
    top, bottom = (line, line) if isinstance(line, (int, float)) else line
    cv2.line(img, (int(top * w), 0), (int(bottom * w), h), (59, 59, 255), 2, cv2.LINE_AA)
    if d is not None:
        pts = [(int(x * w), int(y * h)) for x, y in d.torso]
        for a, b in zip(pts, pts[1:] + pts[:1]):
            cv2.line(img, a, b, (255, 166, 62), 2, cv2.LINE_AA)
        past = direction * (d.x - line_at((top, bottom), d.y)) >= 0
        cv2.circle(img, (int(d.x * w), int(d.y * h)), 8, (94, 197, 34) if past else (0, 212, 255), -1, cv2.LINE_AA)
    return img
