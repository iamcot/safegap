import math

import pytest

from proto import calib, config, distance as dist
from proto.alert import AlertState, LawTable, Level, classify
from proto.eval import evaluate
from proto.lane import Detection, point_in_polygon, roi_to_pixels, select_ego
from proto.pipeline import Pipeline
from proto.tracker import IoUTracker, Kalman1D, iou

LAW = config.load_law()
CFG = config.load()


# --- calib ---
def test_f_from_a4():
    # tờ A4 0.297 m ở 3 m, rộng 151.47 px → f = 1530
    assert calib.f_from_reference(151.47, 3.0) == pytest.approx(1530, rel=1e-3)


def test_f_from_hfov_roundtrip():
    f = calib.f_from_hfov(1920, 70)
    assert 2 * math.degrees(math.atan(960 / f)) == pytest.approx(70)


def test_scale_f():
    assert calib.scale_f(1530, 2100, 1050) == pytest.approx(765)


# --- distance ---
def test_from_width_matches_reference_photo():
    # mục 9: Mazda6 ~10 m, f ≈ 1530, xe rộng 1.8 m → ~275 px
    assert dist.from_width(1530, 1.8, 275.4) == pytest.approx(10.0, rel=1e-2)


def test_from_ground_above_horizon_is_none():
    assert dist.from_ground(1530, 1.2, 400, 500) is None
    assert dist.from_ground(1530, 1.2, 600, 500) == pytest.approx(18.36)


def test_fuse_prefers_width_when_far():
    assert dist.fuse(100.0, 60.0, far_m=40) == 100.0
    assert dist.fuse(20.0, 30.0, far_m=40) == pytest.approx(0.625 * 20 + 0.375 * 30)
    assert dist.fuse(50.0, None) == 50.0


# --- lane ---
ROI = roi_to_pixels(CFG["roi"]["polygon"], 1920, 1080)


def test_point_in_polygon():
    assert point_in_polygon(960, 800, ROI)
    assert not point_in_polygon(100, 800, ROI)
    assert not point_in_polygon(960, 100, ROI)


def test_select_ego_picks_nearest_in_roi():
    far = Detection(930, 520, 990, 560, "car")
    near = Detection(860, 600, 1060, 760, "car")
    side = Detection(100, 700, 400, 950, "truck")  # làn bên, gần hơn nhưng ngoài ROI
    assert select_ego([far, near, side], ROI) is near
    assert select_ego([side], ROI) is None


def test_select_ego_box_touching_bottom_edge():
    d = Detection(700, 700, 1200, 1080, "car")
    assert select_ego([d], ROI) is d


# --- law / alert ---
@pytest.mark.parametrize("v,expected", [(50, 35), (60, 35), (61, 55), (80, 55), (95, 70), (110, 100), (130, 100)])
def test_law_table(v, expected):
    assert LawTable(LAW).d_min(v) == expected


def test_classify():
    assert classify(60, 70) == Level.RED
    assert classify(70, 70) == Level.YELLOW
    assert classify(80, 70) == Level.GREEN


def run_alert(seq, cfg=None):
    a = AlertState(LawTable(LAW), cfg or CFG["alert"])
    return [a.update(t, v, d) for t, v, d in seq]


def test_hysteresis_needs_one_second():
    seq = [(i * 0.1, 90, 100) for i in range(15)]           # GREEN ổn định
    seq += [(1.5 + i * 0.1, 90, 50) for i in range(15)]     # RED từ t=1.5
    out = run_alert(seq)
    levels = [l for l, _ in out]
    assert levels[14] == Level.GREEN
    assert levels[15 + 9] == Level.GREEN      # t=2.4, mới giữ 0.9 s
    assert levels[15 + 10] == Level.RED       # t=2.5, đủ 1 s
    sounds = [s for _, s in out]
    assert sum(sounds) == 1 and sounds[25]


def test_flicker_does_not_switch():
    seq = []
    for i in range(40):
        t = i * 0.1
        seq.append((t, 90, 100 if (i // 3) % 2 == 0 else 50))  # đổi qua lại mỗi 0.3 s
    levels = [l for l, _ in run_alert(seq)]
    assert Level.RED not in levels


def test_no_alert_below_min_speed_or_no_target():
    out = run_alert([(i * 0.1, 30, 10) for i in range(30)])
    assert all(l == Level.NONE for l, _ in out)
    out = run_alert([(i * 0.1, 90, None) for i in range(30)])
    assert all(l == Level.NONE for l, _ in out)


def test_sound_cooldown():
    seq, t = [], 0.0
    for phase in [50, 100, 50, 100, 50]:  # RED, GREEN, RED (quá sớm), GREEN, RED (đủ cooldown)
        for _ in range(15):
            seq.append((t, 90, phase))
            t += 0.1
    seq += [(t + i * 0.1, 90, 50) for i in range(30)]
    sounds = [s for _, s in run_alert(seq)]
    times = [seq[i][0] for i, s in enumerate(sounds) if s]
    assert len(times) >= 1
    assert all(b - a >= 5.0 for a, b in zip(times, times[1:]))


def test_manual_d_min_overrides_law():
    cfg = dict(CFG["alert"], manual_d_min_m=120)
    out = run_alert([(i * 0.1, 90, 100) for i in range(20)], cfg)
    assert out[-1][0] == Level.RED


# --- tracker ---
def test_iou():
    assert iou((0, 0, 10, 10), (0, 0, 10, 10)) == 1.0
    assert iou((0, 0, 10, 10), (20, 20, 30, 30)) == 0.0
    assert iou((0, 0, 10, 10), (5, 0, 15, 10)) == pytest.approx(1 / 3)


def test_tracker_keeps_id():
    tr = IoUTracker()
    a = tr.update([(100, 100, 200, 200)], ["car"])
    b = tr.update([(105, 102, 205, 202)], ["car"])
    c = tr.update([(800, 100, 900, 200), (108, 104, 208, 204)], ["car", "car"])
    assert a == b and c[1] == a[0] and c[0] != a[0]


def test_tracker_drops_after_max_missed():
    tr = IoUTracker(max_missed=2)
    tr.update([(0, 0, 10, 10)], ["car"])
    for _ in range(3):
        tr.update([], [])
    assert not tr.tracks


def test_kalman_smooths_noise():
    import random
    random.seed(0)
    kf = Kalman1D(50)
    raw_err, kf_err = [], []
    for i in range(1, 90):
        truth = 50 - 0.1 * i               # tiến lại gần 3 m/s ở 30 fps
        z = truth * (1 + random.gauss(0, 0.08))
        kf.predict(1 / 30)
        kf.update(z)
        if i > 30:
            raw_err.append(abs(z - truth))
            kf_err.append(abs(kf.distance - truth))
    assert sum(kf_err) < 0.5 * sum(raw_err)
    assert kf.rate == pytest.approx(-3.0, abs=1.5)


# --- pipeline ---
def test_pipeline_end_to_end_red():
    pipe = Pipeline(CFG, LAW, 2100, 1181)
    # xe con rộng 1.8 m ở 40 m → w = 1530*1.8/40 ≈ 68.85 px; v=100 → d_min 70 → RED
    w = 1530 * 1.8 / 40
    box = Detection(1050 - w / 2, 700, 1050 + w / 2, 760, "car")
    res = [pipe.step(i, i / 30, 100, [box]) for i in range(45)]
    assert res[0].d == pytest.approx(40, rel=1e-3)
    assert res[-1].level == "RED" and res[-1].d_min == 70
    assert sum(r.sound for r in res) == 1


# --- eval ---
def test_evaluate():
    gt = [{"clip": "gt", "frame_start": "0", "frame_end": "2", "distance_m": "10"},
          {"clip": "gt", "frame_start": "10", "frame_end": "", "distance_m": "20"},
          {"clip": "missing", "frame_start": "0", "frame_end": "0", "distance_m": "30"}]
    logs = {"gt": [{"frame": "0", "d": "10.5"}, {"frame": "1", "d": "11"}, {"frame": "2", "d": ""},
                   {"frame": "10", "d": "18"}]}
    r = evaluate(gt, logs)
    assert r[0]["est_m"] == pytest.approx(10.75) and r[0]["err_pct"] == pytest.approx(7.5)
    assert r[1]["err_pct"] == pytest.approx(-10)
    assert r[2]["est_m"] is None
