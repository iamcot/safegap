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


def test_labeler_summarize_training_log(tmp_path):
    from proto.labeler import summarize_log

    run = tmp_path / "runs" / "signs_x"
    run.mkdir(parents=True)
    (run / "results.csv").write_text("epoch,time,train/box_loss,metrics/precision(B),metrics/recall(B),metrics/mAP50(B)\n"
                                     "1,300,1.9,0.3,0.2,0.21\n2,600,1.5,0.4,0.3,0.35\n")
    log = (f"Logging results to \x1b[1m{run}\x1b[0m\nStarting training for 80 epochs...\n"
           "\x1b[K       3/80      9.36G      1.445      1.429     0.9278         39       1280: 37% ━━━━╸─── 151/401 1.7it/s 1:34<2:31\r"
           "\x1b[K       4/80      9.36G      1.436      1.253     0.9092         37       1280: 13% ━─── 54/401 1.7it/s 33.5s<3:29\n")
    s = summarize_log(log, started=1000.0, now=1000.0 + 900)
    assert (s["epoch"], s["epochs"], s["step"], s["steps"]) == (4, 80, 54, 401)
    assert abs(s["progress"] - (3 + 54 / 401) / 80) < 1e-3
    assert 20000 < s["eta_s"] < 23000
    assert s["map50"] == [0.21, 0.35] and s["best_map50"] == 0.35
    done = summarize_log(log + "Xong. Export: ./scripts/export_coreml.sh /x/best.pt signs 736,1280\n")
    assert done["stage"] == "done" and done["export"].endswith("signs 736,1280")


def test_labeler_train_job_survives_in_files(tmp_path):
    import time as _t
    from fastapi.testclient import TestClient
    from proto.viewer import create_app

    ds = tmp_path / "ds"
    _session(ds / "inbox", "capture_y", ["car"], {"0000010_00": "0 0.5 0.5 0.2 0.2\n"}, reviewed=True)
    c = TestClient(create_app(make_detector=lambda: None, out_dir=tmp_path / "out", label_dir=ds))
    assert c.post("/api/label/train", json={"merge_only": True}).json() == {"started": True}
    for _ in range(100):
        r = c.get("/api/label/train").json()
        if not r["running"]:
            break
        _t.sleep(0.1)
    assert r["code"] == 0 and "1 phiên" in r["log"]
    # viewer mới (khởi động lại) vẫn đọc được trạng thái từ file
    c2 = TestClient(create_app(make_detector=lambda: None, out_dir=tmp_path / "out", label_dir=ds))
    assert c2.get("/api/label/train").json()["code"] == 0


def test_labeler_suggest_maps_groups_and_skips_existing(tmp_path):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from proto import labeler as L

    assert L.suggest_class("no_stop_park", "signs") == "P.130"
    assert L.suggest_class("warning", "signs") == "warning"
    assert L.suggest_class("person", "drive") is None and L.suggest_class("car", "drive") == "car"
    assert "warning" in L.class_list(tmp_path)

    ds = tmp_path / "ds"
    _session(ds / "inbox", "capture_x", ["car"], {"0000010_00": "0 0.5 0.5 0.2 0.2\n"}, reviewed=False)
    proposed = [{"cls": "P.130", "cx": 0.8, "cy": 0.2, "w": 0.03, "h": 0.05, "conf": 0.7},
                {"cls": "P.130", "cx": 0.801, "cy": 0.2, "w": 0.03, "h": 0.05, "conf": 0.4},   # trùng khung trên
                {"cls": "car", "cx": 0.5, "cy": 0.5, "w": 0.2, "h": 0.2, "conf": 0.9}]         # trùng khung đã có
    app = FastAPI()
    app.include_router(L.make_router(ds, suggester=lambda img: proposed))
    c = TestClient(app)
    r = c.post("/api/label/suggest", json={"session": "capture_x", "frame": "0000010_00",
                                           "boxes": [{"cls": "car", "cx": 0.5, "cy": 0.5, "w": 0.2, "h": 0.2}]})
    assert [(b["cls"], b["conf"]) for b in r.json()["boxes"]] == [("P.130", 0.7)]
    assert c.post("/api/label/suggest", json={"session": "capture_x", "frame": "../x", "boxes": []}).status_code == 400

    # model mới nhất trong runs/*/weights/best.pt
    for i, n in enumerate(["signs_a", "signs_b"]):
        w = ds / "signs" / "runs" / n / "weights" / "best.pt"
        w.parent.mkdir(parents=True)
        w.write_bytes(b"x")
        import os
        os.utime(w, (1000 + i, 1000 + i))
    assert L.Suggester(ds).weights() == {"signs": w, "drive": None, "marks": None}


def _sign_pixels(slashes: int, n: int = 24) -> list:
    """Biển giả: viền đỏ, nền xanh, 1 hoặc 2 vạch đỏ chéo."""
    out = []
    for j in range(n):
        for i in range(n):
            u, v = (i + 0.5) / n, (j + 0.5) / n
            rad = ((u - 0.5) ** 2 + (v - 0.5) ** 2) ** 0.5
            on = rad > 0.4 or abs(u - v) < 0.07 or (slashes == 2 and abs(u + v - 1) < 0.07)
            out.append(((0.85, 0.1, 0.1) if on else (0.1, 0.3, 0.8)) + (u, v))
    return out


def test_labeler_slash_code_splits_no_stop_and_no_park():
    from proto import dataset as D
    from proto import labeler as L

    assert L.slash_code(_sign_pixels(2)) == "P.130"
    assert L.slash_code(_sign_pixels(1)) == "P.131a"
    assert L.slash_code([(0.5, 0.5, 0.5, 0.5, 0.5)]) is None
    assert L.suggest_class("no_park", "signs") == "P.131a"
    assert D.sign_group("P.130") == "no_stop_park" and D.sign_group("P.131b") == "no_park"
    assert D.SIGN_GROUPS[8:12] == ["sign_other", "no_park", "lane_sign", "aux_plate"]
    assert D.sign_group("S.508") == "aux_plate"
    assert D.sign_group("P.127c") == "lane_sign" and D.sign_group("P.127a") == "speed_limit"


def test_lane_signs_and_road_marks(tmp_path):
    from proto import dataset as D
    from proto import labeler as L

    assert D.sign_group("R.411") == "lane_sign" and D.sign_group("R.412a") == "lane_sign"
    assert D.sign_group("R.301a") == "mandatory"
    assert "R.411" in L.sign_names() and "mark_left" in L.class_list(tmp_path)
    assert L.suggest_class("lane_sign", "signs") == "lane_sign" and L.suggest_class("mark_left", "marks") == "mark_left"
    # chỉ ảnh có khung vạch vào bộ marks; khung biển / xe bỏ
    ds = tmp_path / "ds"
    (ds / "images").mkdir(parents=True)
    (ds / "labels").mkdir()
    (ds / "classes.txt").write_text("car\nmark_left\nR.411\n")
    for stem, txt in (("s__0000001_00", "0 .5 .5 .1 .1\n1 .5 .9 .1 .05\n2 .5 .1 .1 .05\n"), ("s__0000002_00", "0 .5 .5 .1 .1\n")):
        (ds / "images" / f"{stem}.jpg").write_bytes(b"x")
        (ds / "labels" / f"{stem}.txt").write_text(txt)
    assert D.sync_own_marks(ds) == 1
    assert (ds / "marks" / "labels" / "s__0000001_00.txt").read_text() == f"{D.MARK_CLASSES.index('mark_left')} .5 .9 .1 .05\n"
    sd = D.to_sign_labels("2 .5 .1 .1 .05\n", ["car", "mark_left", "R.411"])
    assert sd == f"{D.SIGN_GROUPS.index('lane_sign')} .5 .1 .1 .05\n"


def test_speed_value_classes(tmp_path):
    from proto import dataset as D
    from proto import labeler as L

    assert "P.127_50" in L.class_list(tmp_path) and D.sign_group("P.127_120") == "speed_limit"
