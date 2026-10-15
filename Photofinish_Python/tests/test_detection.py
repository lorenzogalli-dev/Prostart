"""Unit tests (no model or video needed):   python -m unittest discover -s tests -v"""
import random
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from finisheye_detection.detector import locate_torso  # noqa: E402
from finisheye_detection.judge import FinishJudge, line_through, official_hundredths  # noqa: E402


def lm(x, y, v=1.0):
    return SimpleNamespace(x=x, y=y, visibility=v)


def pose(**pts):
    p = [lm(0, 0) for _ in range(33)]
    for k, v in pts.items():
        p[int(k[1:])] = lm(*v)
    return p


class TestMethods(unittest.TestCase):
    P = pose(p11=(0.40, 0.30), p12=(0.44, 0.32), p23=(0.38, 0.60), p24=(0.40, 0.62),
             p13=(0.40, 0.45), p14=(0.44, 0.45), p15=(0.42, 0.55), p16=(0.46, 0.55))

    def test_torso_centre_is_mean_of_shoulders_and_hips(self):
        d = locate_torso(self.P, "torso", 640, 360)
        self.assertAlmostEqual(d.x, (0.40 + 0.44 + 0.38 + 0.40) / 4)
        self.assertAlmostEqual(d.y, (0.30 + 0.32 + 0.60 + 0.62) / 4)

    def test_shoulder_midpoint(self):
        d = locate_torso(self.P, "shoulders", 640, 360)
        self.assertAlmostEqual(d.x, 0.42)

    def test_landmarks_front_is_ahead_in_running_direction(self):
        ltr = locate_torso(self.P, "landmarks", 640, 360, direction=1)
        rtl = locate_torso(self.P, "landmarks", 640, 360, direction=-1)
        self.assertGreater(ltr.x, 0.44)
        self.assertLess(rtl.x, 0.38)

    def test_low_visibility_rejected(self):
        p = pose(p11=(0.4, 0.3, 0.1), p12=(0.44, 0.32), p23=(0.38, 0.6), p24=(0.4, 0.62))
        self.assertIsNone(locate_torso(p, "torso", 640, 360))


class TestJudge(unittest.TestCase):
    def run_motion(self, cross_ms, fps=60, noise=0.0, spikes=False):
        j = FinishJudge(line=0.5)
        rng, t = random.Random(1), 0.0
        while t < cross_ms + 1000:
            x = 0.5 + 0.0004 * (t - cross_ms) + rng.gauss(0, noise) + (0.02 if spikes and rng.random() < 0.25 else 0)
            j.push(t, x)
            t += 1000 / fps
        return j

    def test_interpolation_exact(self):
        c = self.run_motion(1234.5).crossing
        self.assertAlmostEqual(c.interpolated, 1234.5, delta=0.01)
        self.assertGreaterEqual(c.first_frame_t, 1234.5)

    def test_fit_with_noise_and_arm_spikes(self):
        c = self.run_motion(2000.0, noise=0.003, spikes=True).refine()
        self.assertEqual(c.method, "fit")
        self.assertLess(abs(c.t - 2000.0), 8.0)

    def test_angled_line_uses_torso_height(self):
        j = FinishJudge(line=(0.60, 0.40))     # x = 0.50 at mid-height
        j.push(0, 0.49, 0.5)
        j.push(10, 0.51, 0.5)
        self.assertAlmostEqual(j.crossing.t, 5.0)
        j2 = FinishJudge(line=(0.60, 0.40))    # higher up the line is at 0.55 → not crossed
        j2.push(0, 0.49, 0.25)
        j2.push(10, 0.51, 0.25)
        self.assertIsNone(j2.crossing)

    def test_right_to_left(self):
        j = FinishJudge(line=0.5, direction=-1)
        for i in range(150):
            j.push(i * 10 + 5.0, 0.9 - 0.004 * (i + 0.5))
        self.assertAlmostEqual(j.crossing.t, 1000.0, delta=0.01)

    def test_two_click_line(self):
        self.assertEqual(tuple(round(v, 6) for v in line_through((0.55, 0.25), (0.45, 0.75))), (0.6, 0.4))

    def test_official_rounding_up(self):
        self.assertEqual(official_hundredths(10.231), 10.24)
        self.assertEqual(official_hundredths(10.230), 10.23)


if __name__ == "__main__":
    unittest.main()
