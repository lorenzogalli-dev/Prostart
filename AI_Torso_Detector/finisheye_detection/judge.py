"""Finish-line judge: torso positions per frame → crossing time.

The signed distance past the line is   s(t) = direction · (x(t) − line_x(y(t)))
where the line's x is taken at the torso point's own height y, so an angled finish line works.

Three answers are produced:

1. ``first_frame_t``  the first frame with s ≥ 0 — what a simple frame-by-frame check reports
                      (always up to one frame late).
2. ``interpolated``   between the last frame before and the first frame after the line, assuming
                      constant speed:  t* = t1 + (t2 − t1) · (−s1) / (s2 − s1)
3. ``t`` (fitted)     after a few more frames, a straight line s(t) = a + b·t is fitted through the
                      frames within ±160 ms and solved for s = 0. Per-frame jitter averages out;
                      outliers ahead of the trend (arms) are trimmed one-sidedly.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

MAX_GAP_MS = 250    # don't interpolate across frames further apart than this
REFINE_MS = 160     # half-window for the line fit (short: athletes dip at the line)
MIN_FIT_PTS = 5


def line_at(line: tuple[float, float], y: float) -> float:
    """x of the finish line at height y. line = (x at top, x at bottom), all fractions of the frame."""
    return line[0] + (line[1] - line[0]) * y


def line_through(p1: tuple[float, float], p2: tuple[float, float]) -> tuple[float, float]:
    """(x at top, x at bottom) of the line through two clicked points (x, y) — fractions of the frame."""
    (x1, y1), (x2, y2) = p1, p2
    if abs(y2 - y1) < 1e-9:
        return (x1 + x2) / 2, (x1 + x2) / 2
    slope = (x2 - x1) / (y2 - y1)
    top = x1 - slope * y1
    return top, top + slope


def official_hundredths(seconds: float) -> float:
    """World Athletics TR 19: fully automatic times are rounded UP to the next 1/100 s."""
    return math.ceil(round(seconds * 1e4) / 100) / 100


@dataclass
class Sample:
    t: float     # ms
    s: float     # signed distance past the line (fraction of frame width)
    x: float
    y: float


@dataclass
class Crossing:
    t: float                     # best estimate (ms) — fitted when possible
    interpolated: float          # between the two frames around the line (ms)
    first_frame_t: float         # first frame past the line (ms)
    method: str                  # 'fit' | 'interpolated' | 'frame'
    uncertainty_ms: float
    frame_gap_ms: float
    fit_points: int = 0


@dataclass
class FinishJudge:
    line: tuple[float, float] | float      # x (vertical line) or (x at top, x at bottom)
    direction: int = 1                     # +1 left→right, −1 right→left
    t_start: float = 0.0                   # ms; crossings earlier than t_start + min_run_ms are ignored
    min_run_ms: float = 0.0
    samples: list = field(default_factory=list)
    crossing: Crossing | None = None

    def __post_init__(self):
        if isinstance(self.line, (int, float)):
            self.line = (float(self.line), float(self.line))

    def push(self, t: float, x: float, y: float = 0.5) -> Crossing | None:
        """Add one frame's torso point. Returns the Crossing the first time the line is crossed."""
        s = self.direction * (x - line_at(self.line, y))
        prev = self.samples[-1] if self.samples else None
        self.samples.append(Sample(t, s, x, y))
        if self.crossing or prev is None or t - self.t_start < self.min_run_ms:
            return None
        if not (prev.s < 0 <= s) or s - prev.s > 0.35:   # no crossing / jump to another person
            return None
        gap = t - prev.t
        if gap <= MAX_GAP_MS:
            tc, method = prev.t + gap * (-prev.s) / (s - prev.s), "interpolated"
        else:
            tc, method = t, "frame"
        self.crossing = Crossing(t=tc, interpolated=tc, first_frame_t=t, method=method,
                                 uncertainty_ms=gap / 2, frame_gap_ms=gap)
        return self.crossing

    def refine(self) -> Crossing | None:
        """Straight-line fit around the crossing. Call after ~0.2 s of frames past the line."""
        c = self.crossing
        if c is None:
            return None
        use = [p for p in self.samples if abs(p.t - c.interpolated) <= REFINE_MS]
        if len(use) < MIN_FIT_PTS:
            return c
        fit = _fit(use)
        for _ in range(3):
            if fit is None:
                break
            res = [p.s - (fit[0] + fit[1] * p.t) for p in use]
            mad = sorted(abs(r) for r in res)[len(res) // 2] or 1e-4
            keep = [p for p, r in zip(use, res) if -4.0 * mad < r < 2.0 * mad]
            if len(keep) < MIN_FIT_PTS or len(keep) == len(use):
                break
            use, fit = keep, _fit(keep)
        if fit is None or fit[1] <= 0:
            return c
        a, b = fit
        t = -a / b
        if abs(t - c.interpolated) > REFINE_MS:
            return c
        n = len(use)
        rms = (sum((p.s - a - b * p.t) ** 2 for p in use) / n) ** 0.5
        c.t, c.method, c.fit_points = t, "fit", n
        c.uncertainty_ms = max(2 * rms / b / n ** 0.5, c.frame_gap_ms / 4)
        return c


def _fit(pts):
    n = len(pts)
    t0 = pts[0].t
    st = sum(p.t - t0 for p in pts)
    ss = sum(p.s for p in pts)
    stt = sum((p.t - t0) ** 2 for p in pts)
    sts = sum((p.t - t0) * p.s for p in pts)
    den = n * stt - st * st
    if n < 2 or not den:
        return None
    b = (n * sts - st * ss) / den
    return (ss - b * st) / n - b * t0, b
