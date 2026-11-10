"""Bảng luật + quyết định cảnh báo có hysteresis (mục 3.6)."""
from enum import Enum
from typing import Optional


class Level(str, Enum):
    NONE = "NONE"      # không cảnh báo (chậm / không có xe cùng làn)
    GREEN = "GREEN"
    YELLOW = "YELLOW"
    RED = "RED"


class LawTable:
    def __init__(self, law_cfg: dict):
        self.rows = sorted(law_cfg["table"], key=lambda r: r["max_kmh"])
        if not self.rows:
            raise ValueError("Bảng luật rỗng")

    def d_min(self, speed_kmh: float) -> float:
        for r in self.rows:
            if speed_kmh <= r["max_kmh"]:
                return float(r["d_min_m"])
        return float(self.rows[-1]["d_min_m"])


def classify(distance_m: float, d_min_m: float, red_ratio: float = 0.9, yellow_ratio: float = 1.1) -> Level:
    if distance_m < red_ratio * d_min_m:
        return Level.RED
    if distance_m < yellow_ratio * d_min_m:
        return Level.YELLOW
    return Level.GREEN


class AlertState:
    """Chỉ đổi trạng thái khi trạng thái mới giữ ổn định >= hold_s. Âm thanh khi vào RED, có cooldown."""

    def __init__(self, law: LawTable, alert_cfg: dict):
        self.law = law
        self.red_ratio = alert_cfg.get("red_ratio", 0.9)
        self.yellow_ratio = alert_cfg.get("yellow_ratio", 1.1)
        self.hold_s = alert_cfg.get("hold_s", 1.0)
        self.min_speed = alert_cfg.get("min_speed_kmh", 40.0)
        self.cooldown = alert_cfg.get("sound_cooldown_s", 5.0)
        self.manual_d_min = alert_cfg.get("manual_d_min_m")
        self.level = Level.NONE
        self._candidate = Level.NONE
        self._candidate_since: Optional[float] = None
        self._last_sound: Optional[float] = None
        self.d_min: Optional[float] = None

    def raw_level(self, t: float, speed_kmh: Optional[float], distance_m: Optional[float]) -> Level:
        if speed_kmh is None or speed_kmh < self.min_speed or distance_m is None:
            self.d_min = None
            return Level.NONE
        self.d_min = float(self.manual_d_min) if self.manual_d_min else self.law.d_min(speed_kmh)
        return classify(distance_m, self.d_min, self.red_ratio, self.yellow_ratio)

    def update(self, t: float, speed_kmh: Optional[float], distance_m: Optional[float]):
        """Trả về (level, play_sound)."""
        raw = self.raw_level(t, speed_kmh, distance_m)
        if raw == self.level:
            self._candidate, self._candidate_since = raw, None
        elif raw != self._candidate or self._candidate_since is None:
            self._candidate, self._candidate_since = raw, t
        if self._candidate != self.level and self._candidate_since is not None \
                and t - self._candidate_since >= self.hold_s:
            prev = self.level
            self.level = self._candidate
            self._candidate_since = None
            if self.level == Level.RED and prev != Level.RED:
                if self._last_sound is None or t - self._last_sound >= self.cooldown:
                    self._last_sound = t
                    return self.level, True
        return self.level, False
