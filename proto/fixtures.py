"""Sinh dữ liệu mẫu (golden) cho unit test Swift: cùng input → output phải khớp bản Python.

    uv run python -m proto.fixtures            # ghi lại file JSON
    uv run python -m proto.fixtures --check    # chỉ kiểm tra file đã commit còn khớp code Python

File ghi vào ios/SafeGapCore/Tests/SafeGapCoreTests/Fixtures/golden.json.
Sửa logic trong proto/ thì chạy lại lệnh trên rồi chạy test Swift (`swift test` trong ios/SafeGapCore).
"""
import argparse
import copy
import json
import random
import sys
from pathlib import Path

from . import config, distance as dist
from .alert import AlertState, LawTable, classify
from .lane import Detection, point_in_polygon, roi_to_pixels, select_ego
from .pipeline import Pipeline
from .tracker import IoUTracker, Kalman1D, iou

OUT = Path(__file__).resolve().parent.parent / "ios" / "SafeGapCore" / "Tests" / "SafeGapCoreTests" / "Fixtures" / "golden.json"


def _det(d: Detection) -> list:
    return [d.x1, d.y1, d.x2, d.y2, d.cls, d.conf]


def _from(row) -> Detection:
    return Detection(*row)


def law_cases(law):
    t = LawTable(law)
    return [{"v": v, "d_min": t.d_min(v)} for v in [0, 40, 59.9, 60, 60.1, 75, 80, 95, 100, 110, 120, 135]]


def classify_cases():
    out = []
    for d, dmin in [(60, 70), (63, 70), (62.99, 70), (70, 70), (76.99, 70), (77, 70), (80, 70), (10, 35)]:
        out.append({"d": d, "d_min": dmin, "level": classify(d, dmin).value})
    return out


def distance_cases():
    w = [{"f": f, "w_real": wr, "w_px": wp, "d": dist.from_width(f, wr, wp)}
         for f, wr, wp in [(1530, 1.8, 275.4), (1400, 2.5, 35), (1530, 1.8, 27.54)]]
    g = [{"f": f, "h": h, "y_bottom": yb, "y_horizon": yh, "d": dist.from_ground(f, h, yb, yh)}
         for f, h, yb, yh in [(1530, 1.2, 600, 500), (1530, 1.2, 400, 500), (1530, 1.2, 500, 500), (1400, 1.35, 900, 486)]]
    fu = [{"d_width": a, "d_ground": b, "far": far, "d": dist.fuse(a, b, far)}
          for a, b, far in [(100, 60, 40), (20, 30, 40), (50, None, 40), (0, 10, 40), (79.9, 70, 40)]]
    sc = [{"f": f, "from": a, "to": b, "d": dist.scale_f_to_frame(f, a, b)} for f, a, b in [(1530, 2100, 1920), (1530, 2100, 1050)]]
    return {"from_width": w, "from_ground": g, "fuse": fu, "scale_f": sc}


def lane_cases(cfg):
    roi = roi_to_pixels(cfg["roi"]["polygon"], 1920, 1080)
    pts = [(960, 800), (100, 800), (960, 100), (960, 1079.999), (806.4, 486), (1113.6, 486), (500, 1000), (384, 1000)]
    pip = [{"x": x, "y": y, "inside": point_in_polygon(x, y, roi)} for x, y in pts]
    sets = [
        [Detection(930, 520, 990, 560, "car"), Detection(860, 600, 1060, 760, "car"), Detection(100, 700, 400, 950, "truck")],
        [Detection(100, 700, 400, 950, "truck")],
        [Detection(700, 700, 1200, 1080, "car")],
        [Detection(900, 500, 1000, 600, "car", 0.5), Detection(890, 505, 1010, 600, "bus", 0.9)],  # y2 bằng nhau: giữ box đầu
        [],
    ]
    sel = []
    for s in sets:
        e = select_ego(s, roi)
        sel.append({"dets": [_det(d) for d in s], "ego": None if e is None else s.index(e)})
    return {"frame_w": 1920, "frame_h": 1080, "roi_norm": cfg["roi"]["polygon"], "point_in_polygon": pip, "select_ego": sel}


def iou_cases():
    pairs = [((0, 0, 10, 10), (0, 0, 10, 10)), ((0, 0, 10, 10), (20, 20, 30, 30)), ((0, 0, 10, 10), (5, 0, 15, 10)),
             ((0, 0, 10, 10), (10, 0, 20, 10)), ((100, 100, 200, 180), (120, 90, 210, 170))]
    return [{"a": list(a), "b": list(b), "iou": iou(a, b)} for a, b in pairs]


def kalman_case():
    rng = random.Random(1)
    kf = Kalman1D(50, accel_sigma=3.0, meas_rel_sigma=0.08)
    steps = []
    for i in range(1, 60):
        dt = 1 / 30 if i % 7 else 2 / 30  # thỉnh thoảng rớt frame
        z = (50 - 0.1 * i) * (1 + rng.gauss(0, 0.08))
        kf.predict(dt)
        kf.update(z)
        steps.append({"dt": dt, "z": z, "d": kf.distance, "rate": kf.rate})
    return {"d0": 50, "accel_sigma": 3.0, "meas_rel_sigma": 0.08, "steps": steps}


def tracker_case():
    tr = IoUTracker(iou_match=0.3, max_missed=2)
    frames = [
        [(100, 100, 200, 200, "car")],
        [(105, 102, 205, 202, "car")],
        [(800, 100, 900, 200, "car"), (108, 104, 208, 204, "truck")],
        [],
        [(810, 100, 910, 200, "car")],
        [],
        [],
        [],  # track 1 mất quá max_missed
        [(110, 104, 210, 204, "car"), (815, 100, 915, 200, "car"), (500, 500, 600, 600, "bus")],
    ]
    steps = []
    for f in frames:
        ids = tr.update([b[:4] for b in f], [b[4] for b in f])
        steps.append({"boxes": [list(b) for b in f], "ids": ids, "alive": sorted(tr.tracks)})
    return {"iou_match": 0.3, "max_missed": 2, "steps": steps}


def alert_cases(cfg, law):
    def run(seq, acfg):
        a = AlertState(LawTable(law), acfg)
        out = []
        for t, v, d in seq:
            lv, s = a.update(t, v, d)
            out.append({"t": t, "v": v, "d": d, "level": lv.value, "sound": s, "d_min": a.d_min})
        return out

    base = cfg["alert"]
    hyst = [(i * 0.1, 90, 100) for i in range(15)] + [(1.5 + i * 0.1, 90, 50) for i in range(15)]
    flick = [(i * 0.1, 90, 100 if (i // 3) % 2 == 0 else 50) for i in range(40)]
    slow = [(i * 0.1, 30 if i < 20 else 90, 10) for i in range(40)]
    none = [(i * 0.1, 90, None if i % 10 < 5 else 60) for i in range(40)] + [(4 + i * 0.1, None, 60) for i in range(15)]
    cool, t = [], 0.0
    for phase in [50, 100, 50, 100, 50]:
        for _ in range(15):
            cool.append((round(t, 10), 90, phase))
            t += 0.1
    cool += [(round(t + i * 0.1, 10), 90, 50) for i in range(30)]
    ramp = [(i * 0.1, 50 + i * 0.5, 120 - i * 0.6) for i in range(150)]
    manual = [(i * 0.1, 90, 100) for i in range(20)]
    return [
        {"name": "hysteresis", "alert": base, "steps": run(hyst, base)},
        {"name": "flicker", "alert": base, "steps": run(flick, base)},
        {"name": "slow", "alert": base, "steps": run(slow, base)},
        {"name": "no_target", "alert": base, "steps": run(none, base)},
        {"name": "cooldown", "alert": base, "steps": run(cool, base)},
        {"name": "ramp", "alert": base, "steps": run(ramp, base)},
        {"name": "manual_d_min", "alert": dict(base, manual_d_min_m=120), "steps": run(manual, dict(base, manual_d_min_m=120))},
    ]


def pipeline_case(cfg, law, name, use_ground, seed):
    """Chuỗi frame tổng hợp: xe trước lại gần dần, nhiễu bề rộng, xe làn bên, box capo, mất xe vài frame."""
    W, H, F = 1920, 1080, 1450.0
    c = copy.deepcopy(cfg)
    c["camera"] = dict(c["camera"], f_px=F, f_px_image_width=W)
    c["distance"] = dict(c["distance"], use_ground=use_ground)
    pipe = Pipeline(c, law, W, H)
    rng = random.Random(seed)
    frames = []
    for i in range(120):
        t = i / 30 + (0.02 if i > 60 else 0.0)  # có 1 bước thời gian lệch
        v = None if i < 3 else 85 + 0.2 * i
        dets = []
        d_true = 100 - 0.5 * i
        if not (80 <= i < 84):  # mất xe phía trước 4 frame
            w = F * 1.8 / d_true * (1 + rng.gauss(0, 0.03))
            cx = 960 + rng.gauss(0, 3)
            y2 = 486 + F * 1.2 / d_true
            dets.append(Detection(cx - w / 2, y2 - 0.8 * w, cx + w / 2, y2, "car", 0.8))
        # xe tải làn trái, gần hơn nhưng ngoài ROI
        dets.append(Detection(250, 520, 600, 800, "truck", 0.7))
        # capo xe mình: rộng gần hết khung và chạm đáy → phải bị bỏ
        dets.append(Detection(100, 900, 1820, 1080, "car", 0.6))
        # box rộng hơn 0.7 khung nhưng không chạm đáy → cũng bỏ
        if i % 10 == 0:
            dets.append(Detection(200, 600, 1700, 1000, "car", 0.4))
        # class không có bề rộng → bỏ
        dets.append(Detection(900, 600, 950, 700, "motorcycle", 0.5))
        r = pipe.step(i, t, v, dets)
        frames.append({"frame": i, "t": t, "speed_kmh": v, "dets": [_det(d) for d in dets], "out": r.row()})
    return {"name": name, "frame_w": W, "frame_h": H, "f_px": F, "config": c, "frames": frames}


def build() -> dict:
    cfg, law = config.load(), config.load_law()
    return {
        "comment": "Sinh bởi `python -m proto.fixtures`. Không sửa tay.",
        "law": law,
        "law_cases": law_cases(law),
        "classify": classify_cases(),
        "distance": distance_cases(),
        "lane": lane_cases(cfg),
        "iou": iou_cases(),
        "kalman": kalman_case(),
        "tracker": tracker_case(),
        "alert": alert_cases(cfg, law),
        "pipeline": [pipeline_case(cfg, law, "width_only", False, 7), pipeline_case(cfg, law, "with_ground", True, 11)],
    }


def dumps(data: dict) -> str:
    return json.dumps(data, ensure_ascii=False, indent=1) + "\n"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--check", action="store_true", help="báo lỗi nếu file đã commit khác output hiện tại")
    args = p.parse_args(argv)
    text = dumps(build())
    if args.check:
        ok = OUT.exists() and OUT.read_text(encoding="utf-8") == text
        print("golden.json khớp" if ok else "golden.json đã cũ: chạy `python -m proto.fixtures`")
        return 0 if ok else 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"đã ghi {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
