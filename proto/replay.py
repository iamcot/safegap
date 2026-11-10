"""Chạy lại pipeline trên detection đã cache (không cần OpenCV/YOLO)."""
from typing import Callable, List, Optional

from .detcache import frame_dets
from .pipeline import FrameResult, Pipeline


def replay(data: dict, cfg: dict, law: dict, speed_at: Callable[[float], Optional[float]]) -> List[FrameResult]:
    pipe = Pipeline(cfg, law, data["width"], data["height"])
    fps = data["fps"]
    return [pipe.step(i, i / fps, speed_at(i / fps), frame_dets(data, i)) for i in range(len(data["frames"]))]
