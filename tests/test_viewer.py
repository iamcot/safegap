import time

import numpy as np
import pytest

from proto import config
from proto.replay import replay
from proto.speed import SpeedTrack

CFG, LAW = config.load(), config.load_law()


def _row():
    w = 1530 * 1.8 / 40
    return [1050 - w / 2, 700, 1050 + w / 2, 760, "car", 0.9]


def test_replay_skips_undetected_frames():
    data = {"fps": 30.0, "width": 2100, "height": 1181,
            "frames": [[_row()]] * 5 + [None] * 3 + [[_row()]] * 5}
    res = replay(data, CFG, LAW, SpeedTrack([0], [100]).at)
    assert len(res) == 13
    assert res[5] is None and res[7] is None
    assert res[4].d == pytest.approx(40, rel=1e-3)
    assert res[8].d == pytest.approx(40, rel=1e-3)   # đoạn sau bắt đầu lại, không lỗi
    assert res[8].frame == 8


@pytest.fixture
def clip(tmp_path):
    cv2 = pytest.importorskip("cv2")
    path = tmp_path / "clip.mp4"
    vw = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), 30, (320, 180))
    for i in range(60):
        vw.write(np.full((180, 320, 3), i * 4, np.uint8))
    vw.release()
    return path


def test_viewer_api_detects_from_playhead(clip, tmp_path):
    from fastapi.testclient import TestClient

    from proto.viewer import create_app
    from proto.lane import Detection

    seen = []

    def fake_detector():
        def det(frame):
            seen.append(int(frame[0, 0, 0]) // 4)
            return [Detection(130, 100, 190, 130, "car", 0.9)]
        return det

    with TestClient(create_app(fake_detector, tmp_path / "out")) as c:
        c.post("/api/state", json={"playhead": 0}).status_code  # chưa mở video
        meta = c.post("/api/open", json={"path": str(clip)}).json()
        assert meta["n_frames"] == 60 and meta["width"] == 320
        c.post("/api/state", json={"playhead": 40})
        for _ in range(100):
            s = c.post("/api/state", json={"playhead": 40}).json()
            if s["done"] == 60:
                break
            time.sleep(0.05)
        assert s["done"] == 60 and s["error"] is None
        r = c.post("/api/params", json={"cfg": CFG, "speed_t": [0], "speed_v": [90]}).json()
        assert len(r["d"]) == 60 and all(d is not None for d in r["d"])
        assert len(r["roi"]) == 4
        d = c.get("/api/frames", params={"start": 10, "end": 12}).json()
        assert d["start"] == 10 and len(d["dets"]) == 2 and d["res"]["d"] == r["d"][10:12]
        assert c.get("/api/results").json()["d"] == r["d"]
        assert c.get("/api/video").status_code == 200
        assert c.get("/").status_code == 200
    assert (tmp_path / "out" / "clip_dets.json").exists()


def test_incremental_replay_matches_full_replay():
    import random

    from proto.replay import IncrementalReplay

    rnd = random.Random(1)
    w = 1530 * 1.8 / 40
    full = []
    for i in range(120):
        k = 1 + 0.004 * i  # xe phía trước tiến lại gần dần
        full.append([] if i % 37 == 5 else [[1050 - w * k / 2, 700, 1050 + w * k / 2, 760, "car", 0.9]])
    speed = SpeedTrack([0], [100]).at
    expect = replay({"fps": 30.0, "width": 2100, "height": 1181, "frames": full}, CFG, LAW, speed)
    shuffled = list(range(120))
    rnd.shuffle(shuffled)
    orders = [list(range(60, 120)) + list(range(0, 60)),   # như viewer: chạy từ chỗ đang xem, rồi quay lại đầu
              shuffled]
    for order in orders:
        inc = IncrementalReplay(30.0, 2100, 1181, CFG, LAW, speed)
        frames = [None] * 120
        for step, i in enumerate(order):
            frames[i] = full[i]
            if step % 7 == 0:
                inc.update(frames)
        got = inc.update(frames)
        assert [r.row() for r in got] == [r.row() for r in expect]


def test_pipeline_ignores_own_hood_box():
    from proto.lane import Detection
    from proto.pipeline import Pipeline

    w = 1530 * 1.8 / 40
    car = Detection(1050 - w / 2, 700, 1050 + w / 2, 760, "car", 0.9)
    hood = Detection(10, 650, 2090, 1181, "car", 0.8)   # capo xe mình: rộng hết khung, chạm đáy
    r = Pipeline(CFG, LAW, 2100, 1181).step(0, 0.0, 100, [hood, car])
    assert r.d == pytest.approx(40, rel=1e-3)
    r = Pipeline(CFG, LAW, 2100, 1181).step(0, 0.0, 100, [hood])
    assert r.d is None
