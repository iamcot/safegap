"""Vẽ overlay lên frame (BGR). Dùng chung cho run_video.py và viewer.py."""
import numpy as np

COLORS = {"GREEN": (0, 200, 0), "YELLOW": (0, 220, 255), "RED": (0, 0, 255), "NONE": (160, 160, 160)}


def draw(cv2, frame, roi_px, dets, r):
    h, w = frame.shape[:2]
    scale = max(1.0, w / 1280)
    cv2.polylines(frame, [np.array(roi_px, dtype=np.int32)], True, (255, 255, 0), max(1, int(2 * scale)))
    for d in dets:
        cv2.rectangle(frame, (int(d.x1), int(d.y1)), (int(d.x2), int(d.y2)), (200, 200, 200), 1)
    color = COLORS[r.level]
    if r.d is not None:
        ego = [d for d in dets if r.w_px is not None and abs(d.width - r.w_px) < 1e-6]
        for d in ego[:1]:
            cv2.rectangle(frame, (int(d.x1), int(d.y1)), (int(d.x2), int(d.y2)), color, max(2, int(3 * scale)))
            cv2.putText(frame, f"{r.d:.0f}m", (int(d.x1), int(d.y1) - 8), cv2.FONT_HERSHEY_SIMPLEX,
                        0.8 * scale, color, max(2, int(2 * scale)))
    bar = int(60 * scale)
    cv2.rectangle(frame, (0, 0), (w, bar), color, -1)
    txt = f"D={r.d:.0f}m" if r.d is not None else "D=--"
    txt += f"  d_min={r.d_min:.0f}m" if r.d_min is not None else "  d_min=--"
    txt += f"  v={r.speed_kmh:.0f}km/h" if r.speed_kmh is not None else "  v=--"
    txt += f"  {r.level}"
    cv2.putText(frame, txt, (int(12 * scale), int(bar * 0.7)), cv2.FONT_HERSHEY_SIMPLEX, 1.0 * scale, (0, 0, 0),
                max(2, int(2 * scale)))
    return frame
