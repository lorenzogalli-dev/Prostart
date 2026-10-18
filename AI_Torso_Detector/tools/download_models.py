"""Download the MediaPipe pose models into models/ (not stored in git).

    python tools/download_models.py            # full (default model)
    python tools/download_models.py lite heavy
"""
import sys
import urllib.request
from pathlib import Path

MODELS = Path(__file__).resolve().parent.parent / "models"
URL = "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_{m}/float16/1/pose_landmarker_{m}.task"

for m in sys.argv[1:] or ["full"]:
    MODELS.mkdir(exist_ok=True)
    out = MODELS / f"pose_landmarker_{m}.task"
    if out.exists():
        print(f"{out.name}: already there")
        continue
    print(f"downloading {out.name} …")
    urllib.request.urlretrieve(URL.format(m=m), out)
    print(f"  {out.stat().st_size / 1e6:.1f} MB")
