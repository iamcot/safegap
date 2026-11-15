"""YOLO wrapper (mục 3.1). Cần: pip install ultralytics."""
from typing import List

from .lane import Detection


class Detector:
    def __init__(self, model: str = "yolo11n.pt", classes=("car", "truck", "bus"), min_conf: float = 0.35,
                 device=None):
        from ultralytics import YOLO  # import trễ để các module khác chạy được khi chưa cài
        self.model = YOLO(model)
        self.device = device if device is not None else _auto_device()
        names = self.model.names
        wanted = set(classes)
        self.class_ids = [i for i, n in names.items() if n in wanted]
        self.names = names
        self.min_conf = min_conf

    def __call__(self, frame) -> List[Detection]:
        res = self.model.predict(frame, classes=self.class_ids, conf=self.min_conf, device=self.device,
                                   verbose=False)[0]
        out = []
        for (x1, y1, x2, y2), c, k in zip(res.boxes.xyxy.tolist(), res.boxes.conf.tolist(), res.boxes.cls.tolist()):
            out.append(Detection(x1, y1, x2, y2, self.names[int(k)], float(c)))
        return out


def _auto_device():
    """GPU nếu có: CUDA, hoặc MPS trên Mac chip Apple (nhanh hơn CPU nhiều lần). Không thì CPU."""
    try:
        import torch
        if torch.cuda.is_available():
            return 0
        if torch.backends.mps.is_available():
            return "mps"
    except Exception:  # noqa: BLE001 - thiếu torch / bản cũ: cứ để ultralytics tự chọn
        pass
    return "cpu"
