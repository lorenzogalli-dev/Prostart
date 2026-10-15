"""finisheye-detection — AI torso finish-line detection (MediaPipe Pose).

    from finisheye_detection import analyze_video
    r = analyze_video("race.mp4", "models/pose_landmarker_full.task", line=0.48, start_s=4.0)
    print(r.seconds())          # fitted crossing time after the start, in seconds
"""
from .detector import METHODS, Detection, TorsoDetector, locate_torso
from .judge import Crossing, FinishJudge, line_at, line_through, official_hundredths
from .video import Result, analyze_video, draw, rotate_frame

__all__ = ["METHODS", "Detection", "TorsoDetector", "locate_torso", "Crossing", "FinishJudge",
           "line_at", "line_through", "official_hundredths", "Result", "analyze_video", "draw",
           "rotate_frame"]
__version__ = "1.0.0"
