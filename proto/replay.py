"""Chạy lại pipeline trên detection đã cache (không cần OpenCV/YOLO).

Frame chưa nhận diện (None trong cache, khi viewer mới chạy YOLO được một phần clip) cho kết quả None.
Sau mỗi khoảng trống, pipeline bắt đầu lại từ đầu (Kalman, cảnh báo) để không nối hai đoạn rời nhau.
"""
from typing import Callable, Dict, List, Optional

from .lane import Detection
from .pipeline import FrameResult, Pipeline


class IncrementalReplay:
    """Như replay() nhưng tính tiếp được khi có thêm frame (YOLO chạy nền), không tính lại từ đầu.

    Kết quả sau mỗi update() luôn giống hệt replay() trên cùng dữ liệu: khi một khoảng trống được lấp
    và nối liền với đoạn phía sau, đoạn phía sau được tính lại vì Kalman/cảnh báo phải chạy liền mạch.
    """

    def __init__(self, fps: float, width: int, height: int, cfg: dict, law: dict,
                 speed_at: Callable[[float], Optional[float]], min_conf: float = 0.0):
        self.fps, self.width, self.height = fps, width, height
        self.cfg, self.law, self.speed_at, self.min_conf = cfg, law, speed_at, min_conf
        self.results: List[Optional[FrameResult]] = []
        self._tails: Dict[int, Pipeline] = {}   # frame cuối của mỗi đoạn → pipeline đã chạy tới đó

    def update(self, frames: List[Optional[list]]) -> List[Optional[FrameResult]]:
        n = len(frames)
        res = self.results
        if len(res) < n:
            res.extend([None] * (n - len(res)))
        elif len(res) > n:
            del res[n:]
            self._tails = {k: v for k, v in self._tails.items() if k < n}
        for i in range(n):
            fr = frames[i]
            if fr is None:
                if res[i] is not None:          # không xảy ra khi frame chỉ được thêm, phòng hờ
                    res[i] = None
                    self._tails.pop(i, None)
                continue
            if res[i] is not None:
                continue
            pipe = self._tails.pop(i - 1, None) if i > 0 and res[i - 1] is not None else None
            if pipe is None:
                pipe = Pipeline(self.cfg, self.law, self.width, self.height)
            t = i / self.fps
            dets = [Detection(*row) for row in fr if row[5] >= self.min_conf]
            res[i] = pipe.step(i, t, self.speed_at(t), dets)
            if i + 1 < n and res[i + 1] is not None:
                # đoạn phía sau từng bắt đầu bằng pipeline mới, giờ nối liền → tính lại cả đoạn đó
                j = i + 1
                while j < n and res[j] is not None:
                    res[j] = None
                    j += 1
                self._tails.pop(j - 1, None)
            self._tails[i] = pipe
        return res


def replay(data: dict, cfg: dict, law: dict,
           speed_at: Callable[[float], Optional[float]]) -> List[Optional[FrameResult]]:
    inc = IncrementalReplay(data["fps"], data["width"], data["height"], cfg, law, speed_at)
    return list(inc.update(data["frames"]))
