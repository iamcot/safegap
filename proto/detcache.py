"""Chạy YOLO 1 lần cho cả clip, lưu JSON. Sau đó chỉnh tham số (f, ROI, W_real, ngưỡng)
và chạy lại pipeline tức thì mà không cần YOLO.

    python -m proto.detcache data/clips/hwy01.mp4          # → out/hwy01_dets.json
"""
import argparse
import json
from pathlib import Path
from typing import Callable, List, Optional

from .lane import Detection


def cache_path(video: str, out_dir: str = "out") -> Path:
    return Path(out_dir) / f"{Path(video).stem}_dets.json"


def detect_video(video: str, detector, progress: Optional[Callable[[int, int], None]] = None) -> dict:
    import cv2
    cap = cv2.VideoCapture(video)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    frames: List[list] = []
    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        frames.append([[round(d.x1, 1), round(d.y1, 1), round(d.x2, 1), round(d.y2, 1), d.cls, round(d.conf, 3)]
                       for d in detector(frame)])
        i += 1
        if progress:
            progress(i, n)
    cap.release()
    return {"video": str(video), "fps": fps, "width": w, "height": h, "frames": frames}


def save(data: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f)


def load(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def frame_dets(data: dict, i: int) -> List[Detection]:
    return [Detection(*row) for row in data["frames"][i]]


def main(argv=None):
    from . import config
    from .detect import Detector
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("video")
    p.add_argument("--out", default="out")
    p.add_argument("--config", default="default.json")
    args = p.parse_args(argv)
    det = Detector(**config.load(args.config)["detection"])
    data = detect_video(args.video, det, lambda i, n: print(f"\r{i}/{n}", end=""))
    path = cache_path(args.video, args.out)
    save(data, path)
    print(f"\n→ {path}")


if __name__ == "__main__":
    main()
