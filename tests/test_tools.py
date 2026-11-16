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


def test_labeler_api_roundtrip(tmp_path):
    import json as _json
    from fastapi.testclient import TestClient
    from proto import dataset as D
    from proto.viewer import create_app

    ds = tmp_path / "ds"
    _session(ds / "inbox", "capture_x", ["car", "truck"],
             {"0000010_00": "1 0.5 0.5 0.2 0.2\n", "0000014_00": "0 0.3 0.3 0.1 0.1\n"}, reviewed=False)
    c = TestClient(create_app(make_detector=lambda: None, out_dir=tmp_path / "out", label_dir=ds))
    assert "Gán nhãn" in c.get("/label").text
    r = c.get("/api/label/sessions").json()
    assert r["sessions"] == [{"name": "capture_x", "images": 2, "reviewed": 0}]
    assert "P.130" in r["classes"] and r["classes"][:2] == ["car", "truck"]
    fr = c.get("/api/label/frames", params={"session": "capture_x"}).json()
    assert [f["id"] for f in fr["frames"]] == ["0000010_00", "0000014_00"] and fr["frames"][0]["speedKmh"] == 30
    b = c.get("/api/label/boxes", params={"session": "capture_x", "frame": "0000010_00"}).json()["boxes"]
    assert b[0]["cls"] == "truck"
    b.append({"cls": "P.130", "cx": 0.8, "cy": 0.2, "w": 0.03, "h": 0.05})
    assert c.post("/api/label/save", json={"session": "capture_x", "frame": "0000010_00", "boxes": b}).json() == {"reviewed": 1}
    assert c.get("/api/label/image", params={"session": "capture_x", "frame": "../x"}).status_code == 400
    # chỉ ảnh đã duyệt vào bộ dữ liệu, lớp biển giữ đúng tên
    s = D.merge([ds / "inbox"], ds)
    assert s["images"] == 1
    lines = (ds / "labels" / "capture_x__0000010_00.txt").read_text().splitlines()
    assert [s["classes"][int(ln.split()[0])] for ln in lines] == ["truck", "P.130"]
    assert _json.loads((ds / "inbox" / "capture_x" / "review.json").read_text()) == {"reviewed": ["0000010_00"]}


def test_dataset_import_roboflow_and_sign_groups(tmp_path):
    from proto import dataset as D

    src = tmp_path / "rf"
    for part in ("train", "valid"):
        (src / part / "images").mkdir(parents=True)
        (src / part / "labels").mkdir(parents=True)
        (src / part / "images" / f"a_{part}.jpg").write_bytes(b"x")
        (src / part / "labels" / f"a_{part}.txt").write_text("1 0.5 0.5 0.02 0.03\n4 0.6 0.4 0.02 0.03\n")
    (src / "data.yaml").write_text("nc: 7\nnames: ['Cam con lai', 'Cam dung va do', 'Cam nguoc chieu', 'Cam re', "
                                   "'Gioi han toc do', 'Hieu lenh', 'Nguy hiem']\n")
    ds = tmp_path / "ds"
    assert D.import_roboflow(src, ds) == {"images": 2, "boxes": 4}
    lb = (ds / "signs" / "labels" / "rf__train__a_train.txt").read_text().split("\n")
    assert [D.SIGN_GROUPS[int(x.split()[0])] for x in lb if x] == ["no_stop_park", "speed_limit"]
    # ảnh tự thu: xe bị bỏ, mã biển gom nhóm; ảnh không biển vẫn giữ (mẫu nền)
    (ds / "images").mkdir()
    (ds / "labels").mkdir()
    (ds / "classes.txt").write_text("car\nP.130\nP.123a\nDP.135\n")
    (ds / "images" / "capture_x__0000010_00.jpg").write_bytes(b"x")
    (ds / "labels" / "capture_x__0000010_00.txt").write_text("0 .5 .5 .1 .1\n1 .2 .2 .02 .02\n2 .3 .2 .02 .02\n3 .4 .2 .02 .02\n")
    (ds / "images" / "capture_x__0000014_00.jpg").write_bytes(b"x")
    assert D.sync_own_signs(ds) == 2
    own = (ds / "signs" / "labels" / "capture_x__0000010_00.txt").read_text().split("\n")
    assert [D.SIGN_GROUPS[int(x.split()[0])] for x in own if x] == ["no_stop_park", "no_turn", "end_restriction"]
    assert (ds / "signs" / "labels" / "capture_x__0000014_00.txt").read_text() == ""
    D.split(ds / "signs")
    val = (ds / "signs" / "val.txt").read_text()
    assert "rf__valid__a_valid.jpg" in val and "rf__train__a_train.jpg" not in val
