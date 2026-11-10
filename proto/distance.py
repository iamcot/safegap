"""Ước lượng khoảng cách (mục 3.3, 3.4 trong SafeGap.md)."""
from typing import Optional


def from_width(f_px: float, w_real_m: float, w_px: float) -> float:
    """D = f_px * W_real / w_px."""
    if w_px <= 0:
        raise ValueError("w_px phải > 0")
    return f_px * w_real_m / w_px


def from_ground(f_px: float, h_cam_m: float, y_bottom_px: float, y_horizon_px: float) -> Optional[float]:
    """D = f_px * h_cam / (y_bottom - y_horizon). None nếu đáy xe nằm trên đường chân trời."""
    dy = y_bottom_px - y_horizon_px
    if dy <= 0:
        return None
    return f_px * h_cam_m / dy


def fuse(d_width: float, d_ground: Optional[float], far_m: float = 40.0) -> float:
    """Trung bình có trọng số. Gần: 2 cách ngang nhau. Xa dần: tin cách bề rộng hơn.

    Trọng số của cách mặt đường giảm tuyến tính từ 0.5 (D=0) về 0 (D>=2*far_m).
    """
    if d_ground is None:
        return d_width
    w_ground = max(0.0, 0.5 * (1.0 - d_width / (2.0 * far_m)))
    return (1.0 - w_ground) * d_width + w_ground * d_ground


def scale_f_to_frame(f_px: float, f_image_width: float, frame_width: float) -> float:
    """f trong config đo ở f_image_width; đổi sang độ rộng frame đang xử lý."""
    return f_px * frame_width / f_image_width
