"""Torso detection for finish-line timing, built on MediaPipe Pose Landmarker.

Athletics rule (World Athletics TR 19.1): a finish is judged on the TORSO — not the head, neck,
arms, legs, hands or feet — reaching the vertical plane of the finish line.

Detection methods (`method=`):

* ``"torso"``        centre of both shoulders AND both hips (landmarks 11, 12, 23, 24).
                     The steadiest point (default), but it lies mid-body, so it crosses later
                     than the chest front.
* ``"shoulders"``    midpoint of the two shoulders (landmarks 11, 12).
* ``"segmentation"`` the chest FRONT from the body silhouette: every image row between shoulders
                     and hips is scanned forward from the torso axis until the silhouette ends;
                     arms are cut out using the elbow/wrist landmarks. Closest to the rule.
* ``"landmarks"``    frontmost shoulder/hip joint + ``chest_factor`` × torso length (no mask).

Every method returns ``Detection.y``: the height of the torso point, where a (possibly angled)
finish line is evaluated.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision

LS, RS, LH, RH = 11, 12, 23, 24          # left/right shoulder, left/right hip
ARMS = [(11, 13, 15), (12, 14, 16)]      # shoulder, elbow, wrist for both arms
METHODS = ("torso", "shoulders", "segmentation", "landmarks")


@dataclass
class Detection:
    x: float                 # torso point / chest front, fraction of frame width (0 = left)
    y: float                 # its height, fraction of frame height (0 = top)
    method: str
    confidence: float        # lowest visibility of the landmarks used
    torso: list = field(default_factory=list)   # [(x, y)] shoulders + hips, for drawing


class TorsoDetector:
    """MediaPipe Pose Landmarker in VIDEO mode. Feed frames in time order.

    >>> with TorsoDetector("models/pose_landmarker_full.task", method="torso") as det:
    ...     d = det.detect(frame_bgr, timestamp_ms, direction=1)
    """

    def __init__(self, model_path: str | Path, method: str = "torso", num_poses: int = 2,
                 chest_factor: float = 0.15):
        if method not in METHODS:
            raise ValueError(f"method must be one of {METHODS}")
        self.method = method
        self.chest_factor = chest_factor
        options = vision.PoseLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=str(model_path)),
            running_mode=vision.RunningMode.VIDEO,
            num_poses=num_poses,
            min_pose_detection_confidence=0.5,
            min_pose_presence_confidence=0.5,
            min_tracking_confidence=0.5,
            output_segmentation_masks=method == "segmentation",
        )
        self._landmarker = vision.PoseLandmarker.create_from_options(options)
        self._last_ts = -1

    def close(self) -> None:
        self._landmarker.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def detect(self, frame_bgr: np.ndarray, timestamp_ms: float, direction: int = 1) -> Detection | None:
        """Detect the torso point in one BGR frame.

        direction: +1 if the athlete runs left→right on screen, −1 for right→left (only used by
        the 'segmentation' and 'landmarks' methods, which look for the chest FRONT)."""
        ts = max(int(timestamp_ms), self._last_ts + 1)  # MediaPipe needs increasing timestamps
        self._last_ts = ts
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB))
        res = self._landmarker.detect_for_video(image, ts)
        if not res.pose_landmarks:
            return None
        h, w = frame_bgr.shape[:2]
        # several people in view (coach, official)? take the largest torso = the nearest athlete
        best = max(range(len(res.pose_landmarks)), key=lambda i: _torso_len(res.pose_landmarks[i], w, h))
        lm = res.pose_landmarks[best]
        mask = None
        if self.method == "segmentation" and res.segmentation_masks:
            mask = res.segmentation_masks[best].numpy_view()
            mask = mask[:, :, 0] if mask.ndim == 3 else mask
        return locate_torso(lm, self.method, w, h, direction, mask, self.chest_factor)


# ---------------------------------------------------------------------------------------------
def locate_torso(lm, method: str, w: int, h: int, direction: int = 1, mask=None,
                 chest_factor: float = 0.15) -> Detection | None:
    """Pure function: pose landmarks (normalised x/y/visibility) → Detection."""
    torso = [(lm[i].x, lm[i].y) for i in (LS, RS, RH, LH)]

    if method == "torso":
        pts = [lm[LS], lm[RS], lm[LH], lm[RH]]
        conf = min(_vis(p) for p in pts)
        if conf < 0.3:
            return None
        return Detection(sum(p.x for p in pts) / 4, sum(p.y for p in pts) / 4, method, conf, torso)

    if method == "shoulders":
        conf = min(_vis(lm[LS]), _vis(lm[RS]))
        if conf < 0.3:
            return None
        return Detection((lm[LS].x + lm[RS].x) / 2, (lm[LS].y + lm[RS].y) / 2, method, conf, torso)

    # --- chest-front methods -----------------------------------------------------------------
    pts = [lm[LS], lm[RS], lm[RH], lm[LH]]
    conf = min(_vis(p) for p in pts)
    if conf < 0.3:
        return None
    sh = ((lm[LS].x + lm[RS].x) / 2 * w, (lm[LS].y + lm[RS].y) / 2 * h)
    hp = ((lm[LH].x + lm[RH].x) / 2 * w, (lm[LH].y + lm[RH].y) / 2 * h)
    L = math.hypot(sh[0] - hp[0], sh[1] - hp[1])
    if L < 8:
        return None  # too small / far away
    xs = [p.x * w for p in pts]
    front = max(xs) if direction > 0 else min(xs)
    lm_edge = front + direction * chest_factor * L          # anatomical estimate
    edge = lm_edge
    if method == "segmentation" and mask is not None:
        seg = _silhouette_front(lm, mask, w, h, sh, hp, L, direction, lm_edge)
        if seg is not None:
            edge = seg
    chest_y = (sh[1] + (hp[1] - sh[1]) * 0.25) / h          # a quarter of the way down the torso
    return Detection(edge / w, chest_y, method, conf, torso)


def _silhouette_front(lm, mask, w, h, sh, hp, L, d, lm_edge):
    mh, mw = mask.shape[:2]
    sx, sy = mw / w, mh / h
    # arm corridors (shoulder→elbow→wrist→hand) for BOTH arms: the far arm is often hidden in
    # the landmarks yet visible in the silhouette, swinging past the chest
    arm_r = 0.1 * L
    segs = []
    for s, e, wr in ARMS:
        S, E, W = ((lm[i].x * w, lm[i].y * h) for i in (s, e, wr))
        hand = (W[0] + (W[0] - E[0]) * 0.4, W[1] + (W[1] - E[1]) * 0.4)
        segs += [(S, E), (E, W), (W, hand)]

    clean, blocked = [], []
    core = 0.12 * L            # an arm may overlap the torso core in side view; cut only beyond it
    f = 0.12
    while f <= 0.88:           # rows between just below the shoulders and just above the hips
        y = sh[1] + (hp[1] - sh[1]) * f
        cx = sh[0] + (hp[0] - sh[0]) * f
        f += 0.04
        my = int(round(y * sy))
        if not 0 <= my < mh:
            continue
        row = mask[my]
        x, gap, last, hit_arm = cx, 0, None, False
        while abs(x - cx) <= 0.75 * L:
            mx = int(round(x * sx))
            if not 0 <= mx < mw:
                break
            if d * (x - cx) > core and any(_seg_dist(x, y, a, b) < arm_r for a, b in segs):
                hit_arm = True
                break
            if row[mx] >= 0.5:
                last, gap = x, 0
            else:
                gap += 1
                if gap > 2:
                    break
            x += d
        if last is not None:
            (blocked if hit_arm else clean).append(last)

    edges = clean if len(clean) >= 4 else clean + blocked
    if len(edges) < 4:
        return None
    edges.sort(key=lambda v: d * v)
    e = edges[int(len(edges) * 0.8)]           # 80th percentile: robust to a stray forearm
    lo, hi = lm_edge - d * 0.3 * L, lm_edge + d * 0.15 * L
    return min(max(e, lo), hi) if d > 0 else max(min(e, lo), hi)


def _torso_len(lm, w, h) -> float:
    sx, sy = (lm[LS].x + lm[RS].x) / 2 * w, (lm[LS].y + lm[RS].y) / 2 * h
    hx, hy = (lm[LH].x + lm[RH].x) / 2 * w, (lm[LH].y + lm[RH].y) / 2 * h
    return math.hypot(sx - hx, sy - hy)


def _vis(p) -> float:
    v = getattr(p, "visibility", None)
    return 1.0 if v is None else float(v)


def _seg_dist(px, py, a, b) -> float:
    vx, vy = b[0] - a[0], b[1] - a[1]
    t = max(0.0, min(1.0, ((px - a[0]) * vx + (py - a[1]) * vy) / ((vx * vx + vy * vy) or 1)))
    return math.hypot(px - (a[0] + t * vx), py - (a[1] + t * vy))
