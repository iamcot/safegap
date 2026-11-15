"""Ghép các bước cho 1 frame: chọn xe cùng làn → D → Kalman → cảnh báo.

Tách riêng khỏi run_video.py để test được mà không cần OpenCV/YOLO, và để
bản Swift có thể port 1-1.
"""
from dataclasses import dataclass, asdict
from typing import Optional, Sequence

from . import distance as dist
from .alert import AlertState, LawTable, Level
from .lane import Detection, roi_to_pixels, select_ego
from .tracker import IoUTracker


@dataclass
class FrameResult:
    frame: int
    t: float
    speed_kmh: Optional[float]
    cls: Optional[str] = None
    w_px: Optional[float] = None
    d_raw: Optional[float] = None
    d: Optional[float] = None
    d_min: Optional[float] = None
    level: str = Level.NONE.value
    sound: bool = False
    track_id: Optional[int] = None

    def row(self) -> dict:
        return asdict(self)


class Pipeline:
    def __init__(self, cfg: dict, law_cfg: dict, frame_w: int, frame_h: int):
        cam = cfg["camera"]
        self.f_px = dist.scale_f_to_frame(cam["f_px"], cam["f_px_image_width"], frame_w)
        self.h_cam = cam.get("h_cam_m", 1.2)
        self.widths = cfg["vehicle_width_m"]
        self.roi = roi_to_pixels(cfg["roi"]["polygon"], frame_w, frame_h)
        dcfg = cfg.get("distance", {})
        self.use_ground = dcfg.get("use_ground", False)
        self.y_horizon = dcfg.get("y_horizon_norm", 0.45) * frame_h
        self.fuse_far = dcfg.get("fuse_far_m", 40.0)
        tcfg = cfg.get("tracker", {})
        self.tracker = IoUTracker(**tcfg)
        self.alert = AlertState(LawTable(law_cfg), cfg["alert"])
        self._last_t: Optional[float] = None

    def step(self, frame_idx: int, t: float, speed_kmh: Optional[float], dets: Sequence[Detection]) -> FrameResult:
        dt = 0.0 if self._last_t is None else t - self._last_t
        self._last_t = t
        dets = [d for d in dets if d.cls in self.widths and d.width > 0]
        ids = self.tracker.update([d.box() for d in dets], [d.cls for d in dets])
        r = FrameResult(frame_idx, t, speed_kmh)
        ego = select_ego(dets, self.roi)
        if ego is not None:
            tid = ids[dets.index(ego)]
            d_raw = dist.from_width(self.f_px, self.widths[ego.cls], ego.width)
            if self.use_ground:
                d_raw = dist.fuse(d_raw, dist.from_ground(self.f_px, self.h_cam, ego.y2, self.y_horizon), self.fuse_far)
            r.cls, r.w_px, r.d_raw, r.track_id = ego.cls, ego.width, d_raw, tid
            r.d = self.tracker.update_distance(tid, d_raw, dt)
        level, sound = self.alert.update(t, speed_kmh, r.d)
        r.level, r.sound, r.d_min = level.value, sound, self.alert.d_min
        return r
