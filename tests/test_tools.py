import io

import pytest

from proto import config
from proto.detcache import frame_dets
from proto.replay import replay
from proto.speed import SpeedTrack

CFG, LAW = config.load(), config.load_law()


def test_speed_track_interpolates():
    s = SpeedTrack.from_csv(io.StringIO("t_s,speed_kmh\n10,100\n0,80\n"))  # không cần đã sắp xếp
    assert s.at(-1) == 80 and s.at(5) == pytest.approx(90) and s.at(99) == 100
    assert SpeedTrack().at(1) is None


def test_replay_matches_cached_dets():
    w = 1530 * 1.8 / 40
    row = [1050 - w / 2, 700, 1050 + w / 2, 760, "car", 0.9]
    data = {"fps": 30.0, "width": 2100, "height": 1181, "frames": [[row] for _ in range(45)] + [[]]}
    assert frame_dets(data, 0)[0].cls == "car"
    res = replay(data, CFG, LAW, SpeedTrack([0], [100]).at)
    assert len(res) == 46
    assert res[0].d == pytest.approx(40, rel=1e-3)
    assert res[44].level == "RED"
    assert res[45].d is None
