"""Tốc độ xe mình theo thời gian video. CSV cột t_s,speed_kmh, nội suy tuyến tính."""
import bisect
import csv


class SpeedTrack:
    def __init__(self, t=None, v=None):
        self.t, self.v = list(t or []), list(v or [])

    @classmethod
    def from_csv(cls, path_or_file):
        f = open(path_or_file, newline="") if isinstance(path_or_file, str) else path_or_file
        try:
            rows = list(csv.DictReader(f))
        finally:
            if isinstance(path_or_file, str):
                f.close()
        rows.sort(key=lambda r: float(r["t_s"]))
        return cls([float(r["t_s"]) for r in rows], [float(r["speed_kmh"]) for r in rows])

    def at(self, t: float):
        if not self.t:
            return None
        i = bisect.bisect_left(self.t, t)
        if i <= 0:
            return self.v[0]
        if i >= len(self.t):
            return self.v[-1]
        t0, t1, v0, v1 = self.t[i - 1], self.t[i], self.v[i - 1], self.v[i]
        return v0 + (v1 - v0) * (t - t0) / (t1 - t0)
