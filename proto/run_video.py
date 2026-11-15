"""Chạy pipeline trên video, xuất video có overlay + CSV log mỗi frame.

    pip install -r proto/requirements.txt
    python -m proto.run_video data/clips/hwy01.mp4 --speed data/clips/hwy01_speed.csv --out out/

File tốc độ (tuỳ chọn): CSV có cột t_s,speed_kmh (t_s tính từ đầu video). Nội suy tuyến tính.
Không có file tốc độ thì dùng --const-speed.
"""
import argparse
import csv
from pathlib import Path

from . import config
from .overlay import draw
from .pipeline import Pipeline
from .speed import SpeedTrack


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("video")
    p.add_argument("--speed", help="CSV t_s,speed_kmh")
    p.add_argument("--const-speed", type=float, default=None, help="tốc độ cố định (km/h) nếu không có file")
    p.add_argument("--config", default="default.json")
    p.add_argument("--out", default="out")
    p.add_argument("--no-video", action="store_true", help="chỉ ghi CSV")
    args = p.parse_args(argv)

    import cv2
    from .detect import Detector

    cfg, law = config.load(args.config), config.load_law()
    cap = cv2.VideoCapture(args.video)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    w, h = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    det = Detector(**cfg["detection"])
    pipe = Pipeline(cfg, law, w, h)
    speed = SpeedTrack.from_csv(args.speed) if args.speed else None

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = Path(args.video).stem
    writer = None
    if not args.no_video:
        writer = cv2.VideoWriter(str(out_dir / f"{stem}_overlay.mp4"), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    with open(out_dir / f"{stem}.csv", "w", newline="") as fcsv:
        log = None
        i = 0
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            t = i / fps
            v = speed.at(t) if speed else args.const_speed
            dets = det(frame)
            r = pipe.step(i, t, v, dets)
            if log is None:
                log = csv.DictWriter(fcsv, fieldnames=list(r.row()))
                log.writeheader()
            log.writerow(r.row())
            if writer is not None:
                draw(cv2, frame, pipe.roi, dets, r)
                writer.write(frame)
            i += 1
    cap.release()
    if writer is not None:
        writer.release()
    print(f"Xong {i} frame → {out_dir}/")


if __name__ == "__main__":
    main()
