"""Chọn xe cùng làn bằng ROI hình thang (mục 3.2)."""
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple


@dataclass
class Detection:
    x1: float
    y1: float
    x2: float
    y2: float
    cls: str
    conf: float = 1.0

    @property
    def width(self) -> float:
        return self.x2 - self.x1

    @property
    def bottom_center(self) -> Tuple[float, float]:
        return ((self.x1 + self.x2) / 2.0, self.y2)

    def box(self) -> Tuple[float, float, float, float]:
        return (self.x1, self.y1, self.x2, self.y2)


def point_in_polygon(x: float, y: float, poly: Sequence[Tuple[float, float]]) -> bool:
    """Ray casting."""
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y):
            x_cross = xi + (y - yi) * (xj - xi) / (yj - yi)
            if x < x_cross:
                inside = not inside
        j = i
    return inside


def roi_to_pixels(poly_norm: Sequence[Sequence[float]], img_w: int, img_h: int) -> List[Tuple[float, float]]:
    return [(x * img_w, y * img_h) for x, y in poly_norm]


def select_ego(dets: Sequence[Detection], roi_px: Sequence[Tuple[float, float]]) -> Optional[Detection]:
    """Xe có tâm đáy trong ROI và gần nhất (y2 lớn nhất)."""
    best = None
    y_max = max(y for _, y in roi_px)
    for d in dets:
        cx, cy = d.bottom_center
        cy = min(cy, y_max - 1e-6)  # xe sát mép dưới khung hình vẫn tính là trong ROI
        if point_in_polygon(cx, cy, roi_px) and (best is None or d.y2 > best.y2):
            best = d
    return best
