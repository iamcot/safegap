"""Kalman 1D (D, dD/dt) + tracking bằng IoU (mục 3.5)."""
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

Box = Tuple[float, float, float, float]


class Kalman1D:
    """Mô hình vận tốc không đổi. Nhiễu đo tỉ lệ với D (xa thì kém chính xác hơn)."""

    def __init__(self, d0: float, accel_sigma: float = 3.0, meas_rel_sigma: float = 0.08):
        self.x = np.array([d0, 0.0])
        r = meas_rel_sigma * d0
        self.P = np.diag([r * r, 25.0])
        self.accel_sigma = accel_sigma
        self.meas_rel_sigma = meas_rel_sigma

    @property
    def distance(self) -> float:
        return float(self.x[0])

    @property
    def rate(self) -> float:
        """dD/dt (m/s). Âm = đang lại gần."""
        return float(self.x[1])

    def predict(self, dt: float) -> None:
        F = np.array([[1.0, dt], [0.0, 1.0]])
        q = self.accel_sigma ** 2
        Q = q * np.array([[dt ** 4 / 4, dt ** 3 / 2], [dt ** 3 / 2, dt ** 2]])
        self.x = F @ self.x
        self.P = F @ self.P @ F.T + Q

    def update(self, z: float) -> None:
        H = np.array([1.0, 0.0])
        r = self.meas_rel_sigma * max(z, 1.0)
        S = H @ self.P @ H + r * r
        K = self.P @ H / S
        self.x = self.x + K * (z - H @ self.x)
        self.P = (np.eye(2) - np.outer(K, H)) @ self.P


def iou(a: Box, b: Box) -> float:
    ix1, iy1 = max(a[0], b[0]), max(a[1], b[1])
    ix2, iy2 = min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, ix2 - ix1) * max(0.0, iy2 - iy1)
    if inter == 0:
        return 0.0
    area_a = (a[2] - a[0]) * (a[3] - a[1])
    area_b = (b[2] - b[0]) * (b[3] - b[1])
    return inter / (area_a + area_b - inter)


@dataclass
class Track:
    id: int
    box: Box
    cls: str
    kf: Optional[Kalman1D] = None
    missed: int = 0
    hits: int = 1


class IoUTracker:
    """Ghép box giữa các frame theo IoU (tham lam). Mỗi track giữ 1 Kalman cho D."""

    def __init__(self, iou_match: float = 0.3, max_missed: int = 10,
                 accel_sigma: float = 3.0, meas_rel_sigma: float = 0.08):
        self.iou_match = iou_match
        self.max_missed = max_missed
        self.accel_sigma = accel_sigma
        self.meas_rel_sigma = meas_rel_sigma
        self.tracks: Dict[int, Track] = {}
        self._next_id = 1

    def update(self, boxes: Sequence[Box], classes: Sequence[str]) -> List[Optional[int]]:
        """Trả về track id cho từng box (cùng thứ tự)."""
        pairs = []
        for tid, t in self.tracks.items():
            for i, b in enumerate(boxes):
                s = iou(t.box, b)
                if s >= self.iou_match:
                    pairs.append((s, tid, i))
        pairs.sort(reverse=True)
        used_t, assigned = set(), [None] * len(boxes)
        for s, tid, i in pairs:
            if tid in used_t or assigned[i] is not None:
                continue
            used_t.add(tid)
            assigned[i] = tid
            t = self.tracks[tid]
            t.box, t.cls, t.missed, t.hits = boxes[i], classes[i], 0, t.hits + 1
        for tid in list(self.tracks):
            if tid not in used_t:
                self.tracks[tid].missed += 1
                if self.tracks[tid].missed > self.max_missed:
                    del self.tracks[tid]
        for i, b in enumerate(boxes):
            if assigned[i] is None:
                tid = self._next_id
                self._next_id += 1
                self.tracks[tid] = Track(tid, b, classes[i])
                assigned[i] = tid
        return assigned

    def update_distance(self, tid: int, d_meas: float, dt: float) -> float:
        """Lọc D đo được của track tid, trả về D đã làm mượt."""
        t = self.tracks[tid]
        if t.kf is None:
            t.kf = Kalman1D(d_meas, self.accel_sigma, self.meas_rel_sigma)
        else:
            t.kf.predict(dt)
            t.kf.update(d_meas)
        return t.kf.distance
