"""YOLO wrapper (mục 3.1). Cần: pip install ultralytics."""
from typing import List

from .lane import Detection


class Detector:
    def __init__(self, model: str = "yolo11n.pt", classes=("car", "truck", "bus"), min_conf: float = 0.35):
        from ultralytics import YOLO  # import trễ để các module khác chạy được khi chưa cài
        self.model = YOLO(model)
        names = self.model.names
        wanted = set(classes)
        self.class_ids = [i for i, n in names.items() if n in wanted]
        self.names = names
        self.min_conf = min_conf

    def __call__(self, frame) -> List[Detection]:
        res = self.model.predict(frame, classes=self.class_ids, conf=self.min_conf, verbose=False)[0]
        out = []
        for (x1, y1, x2, y2), c, k in zip(res.boxes.xyxy.tolist(), res.boxes.conf.tolist(), res.boxes.cls.tolist()):
            out.append(Detection(x1, y1, x2, y2, self.names[int(k)], float(c)))
        return out
