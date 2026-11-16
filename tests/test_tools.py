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


def test_triplog_summary(tmp_path):
    from proto import triplog
    head = "frame,t,speed_kmh,cls,w_px,d_raw,d,d_min,level,sound,track_id,time,f_px,f_source,n_dets,infer_ms,speed_acc_kmh,thermal,lane\n"
    rows = []
    for i in range(60):
        lvl = "GREEN" if i < 30 else "RED"
        rows.append(f"{i},{i / 30:.4f},90.0,car,60,45,45,70.0,{lvl},{'True' if i == 30 else 'False'},1,x,1450,intrinsics,1,20,,"
                    f"nominal,{'LR' if i % 2 else ''}")
    p = tmp_path / "log.csv"
    p.write_text(head + "\n".join(rows) + "\n")
    s = triplog.summarize(triplog.load(p))
    assert s["frames"] == 60 and s["red_alerts"] == 1
    assert s["fps"] == pytest.approx(30, rel=1e-3)
    assert s["level_s"]["GREEN"] == pytest.approx(1.0, abs=0.05)
    assert s["lane_pct"]["LR"] == pytest.approx(50)
    assert "Số lần kêu (vào RED): 1" in triplog.report("log.csv", s)
    assert triplog.plot(triplog.load(p), tmp_path / "log.png").exists()


# --- proto.dataset (gộp ảnh tự thu) ---
def _session(root, name, classes, files, reviewed=True):
    import json as _json
    d = root / name
    (d / "images").mkdir(parents=True)
    (d / "labels").mkdir()
    (d / "classes.txt").write_text("\n".join(classes) + "\n")
    with open(d / "meta.jsonl", "w") as mf:
        for stem, label in files.items():
            (d / "images" / f"{stem}.jpg").write_bytes(b"jpg")
            (d / "labels" / f"{stem}.txt").write_text(label)
            mf.write(_json.dumps({"file": f"{stem}.jpg", "speedKmh": 30}) + "\n")
    if reviewed:
        (d / "REVIEWED").write_text("")
    return d


def test_dataset_merge_remaps_classes_and_skips_unreviewed(tmp_path):
    import zipfile
    from proto import dataset as D

    a = _session(tmp_path, "capture_a", ["car", "truck"], {"0000010_00": "1 0.5 0.5 0.1 0.1\n"})
    b = _session(tmp_path, "capture_b", ["car", "P.130", "truck"],
                 {"0000020_00": "1 0.2 0.2 0.05 0.05\n2 0.5 0.5 0.1 0.1\nbad line\n"})
    _session(tmp_path, "capture_c", ["car"], {"0000030_00": "0 0.5 0.5 0.1 0.1\n"}, reviewed=False)
    zp = tmp_path / "capture_b.zip"
    with zipfile.ZipFile(zp, "w") as z:
        for f in b.rglob("*"):
            z.write(f, f.relative_to(tmp_path))
    ds = tmp_path / "ds"
    s = D.merge([a, zp, tmp_path / "capture_c"], ds)
    assert s["classes"] == ["car", "truck", "P.130"]
    assert s["skipped"] == ["capture_c"]
    assert (ds / "labels" / "capture_a__0000010_00.txt").read_text().split()[0] == "1"
    lb = (ds / "labels" / "capture_b__0000020_00.txt").read_text().splitlines()
    assert [ln.split()[0] for ln in lb] == ["2", "1"]
    assert len((ds / "meta.jsonl").read_text().splitlines()) == 2


def test_dataset_split_groups_by_time_cluster(tmp_path):
    from proto import dataset as D

    # ảnh trong cùng cụm 2 phút luôn cùng một phía
    assert D.is_val("capture_x__0000100_00") == D.is_val("capture_x__0000110_00")
    ds = tmp_path / "ds"
    (ds / "images").mkdir(parents=True)
    for i in range(0, 3600, 4):
        (ds / "images" / f"capture_x__{i:07d}_00.jpg").write_bytes(b"")
    (ds / "classes.txt").write_text("car\nP.130\n")
    yaml = D.split(ds)
    val = (ds / "val.txt").read_text().splitlines()
    train = (ds / "train.txt").read_text().splitlines()
    assert len(val) + len(train) == 900 and val and not set(val) & set(train)
    assert '1: "P.130"' in yaml.read_text()
