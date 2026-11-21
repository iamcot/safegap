"""Gộp ảnh tự thu trên xe thành bộ dữ liệu YOLO và train trên Mac (docs/DRIVER_ASSIST.md, B2/B3).

Luồng mỗi tối:
  1. App > Cài đặt > Phiên thu dữ liệu > chia sẻ .zip sang Mac (AirDrop).
  2. Gán nhãn trong CVAT / Label Studio (mở thẳng thư mục phiên: images/ + labels/ + classes.txt, định dạng YOLO).
     Thêm lớp mới (biển báo...) vào cuối classes.txt; xuất lại YOLO đè lên labels/.
     Xong phiên nào thì tạo file rỗng `REVIEWED` trong thư mục phiên đó (nhãn máy chưa sửa chỉ dạy lại lỗi cũ).
     Hoặc dùng trang gán nhãn có sẵn: `uv run python -m proto.viewer` → http://127.0.0.1:8501/label (proto/labeler.py),
     duyệt từng ảnh (ghi review.json), có nút Gộp + Train luôn.
  3. Gộp:   uv run python -m proto.dataset merge ~/Downloads/capture_*.zip ~/Downloads/capture_2026*/
  4. Train: uv run python -m proto.dataset train --epochs 80          (mặc định --device mps, từ yolo11n.pt)
  5. Export Core ML: ./scripts/export_coreml.sh ~/safegap-dataset/drive/runs/<tên>/weights/best.pt

Bộ dò biển (B3), train riêng, lớp = nhóm biển (SIGN_GROUPS):
  uv run python -m proto.dataset import-roboflow ~/datasets/vn-signs     # bộ Zalo trên Roboflow, YOLOv11
  uv run python -m proto.dataset train --task signs --batch 8 --name signs
  (ảnh tự thu đã duyệt tự được thêm vào, mã biển QCVN gom về nhóm; ảnh không biển làm mẫu nền)

Bộ dò vạch / mũi tên mặt đường, train riêng, lớp = MARK_CLASSES (chỉ ảnh tự thu có ít nhất một khung vạch):
  uv run python -m proto.dataset train --task marks --name marks

Cấu trúc bộ dữ liệu (mặc định ~/safegap-dataset, đổi bằng SAFEGAP_DATASET_DIR):
  images/<phiên>__<frame>.jpg, labels/<phiên>__<frame>.txt
  classes.txt        hợp các lớp của mọi phiên, theo tên (lớp mới thêm vào cuối, chỉ số cũ không đổi)
  meta.jsonl         meta từng ảnh (GPS, tốc độ, đèn...) kèm "session"
  train.txt, val.txt, data.yaml   sinh lúc split/train
Chia train/val theo **cụm 2 phút** của từng phiên (ảnh cách nhau 4 s gần như giống hệt; chia từng ảnh sẽ rò rỉ).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import zipfile
from pathlib import Path

DEFAULT_DIR = Path.home() / "safegap-dataset"
VAL_FRACTION = 0.15
CLUSTER_S = 120.0
REVIEWED_MARK = "REVIEWED"
REVIEW_FILE = "review.json"   # trang gán nhãn (proto.labeler) ghi: {"reviewed": [frame, ...]}


def dataset_dir() -> Path:
    raw = os.environ.get("SAFEGAP_DATASET_DIR")
    return Path(raw).expanduser() if raw else DEFAULT_DIR


def read_classes(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [ln.strip() for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]


def merge_classes(base: list[str], new: list[str]) -> list[str]:
    out = list(base)
    for c in new:
        if c not in out:
            out.append(c)
    return out


def remap_label_text(text: str, src: list[str], dst: list[str]) -> str:
    """Đổi chỉ số lớp của một file nhãn YOLO từ danh sách `src` sang `dst` (theo tên). Bỏ dòng hỏng."""
    lines = []
    for ln in text.splitlines():
        parts = ln.split()
        if len(parts) != 5:
            continue
        try:
            idx = int(parts[0])
            vals = [float(v) for v in parts[1:]]
        except ValueError:
            continue
        if not 0 <= idx < len(src):
            continue
        cx, cy, w, h = vals
        if w <= 0 or h <= 0:
            continue
        lines.append(f"{dst.index(src[idx])} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")
    return "\n".join(lines) + ("\n" if lines else "")


def frame_time(stem: str) -> float:
    """Tên ảnh do app đặt: thời gian frame, '.' thay bằng '_' (vd 0000123_45)."""
    try:
        return float(stem.replace("_", "."))
    except ValueError:
        return 0.0


def _session_dirs(src: Path, tmp: Path) -> list[Path]:
    if src.is_file() and src.suffix == ".zip":
        out = tmp / src.stem
        with zipfile.ZipFile(src) as z:
            for name in z.namelist():   # chặn đường dẫn kiểu ../
                if name.startswith("/") or ".." in Path(name).parts:
                    raise ValueError(f"zip có đường dẫn lạ: {name}")
            z.extractall(out)
        src = out
    if (src / "images").is_dir():
        return [src]
    return sorted(p for p in src.rglob("*") if p.is_dir() and (p / "images").is_dir())


def merge(sources: list[Path], ds: Path, *, only_reviewed: bool = True) -> dict:
    """Chép các phiên vào bộ dữ liệu. Chạy lại an toàn: ảnh trùng tên thì ghi đè (nhãn mới nhất thắng)."""
    (ds / "images").mkdir(parents=True, exist_ok=True)
    (ds / "labels").mkdir(parents=True, exist_ok=True)
    classes = read_classes(ds / "classes.txt")
    stats = {"sessions": 0, "skipped": [], "images": 0, "boxes": 0}
    meta_out = ds / "meta.jsonl"
    with tempfile.TemporaryDirectory() as t:
        for src in sources:
            for sess in _session_dirs(Path(src).expanduser(), Path(t)):
                name = sess.name
                keep = reviewed_frames(sess) if only_reviewed else None
                if keep is not None and not keep:
                    stats["skipped"].append(name)
                    continue
                src_classes = read_classes(sess / "classes.txt")
                classes = merge_classes(classes, src_classes)
                metas = {}
                if (sess / "meta.jsonl").exists():
                    for ln in (sess / "meta.jsonl").read_text(encoding="utf-8").splitlines():
                        try:
                            m = json.loads(ln)
                            metas[Path(m["file"]).stem] = m
                        except (ValueError, KeyError, TypeError):
                            continue
                old = meta_out.read_text(encoding="utf-8").splitlines() if meta_out.exists() else []
                old = [ln for ln in old if f'"session": "{name}"' not in ln]   # chạy lại: thay meta cũ của phiên
                meta_out.write_text("".join(ln + "\n" for ln in old), encoding="utf-8")
                with meta_out.open("a", encoding="utf-8") as mf:
                    for img in sorted((sess / "images").glob("*.jpg")):
                        if keep is not None and img.stem not in keep:
                            continue
                        fid = f"{name}__{img.stem}"
                        shutil.copy2(img, ds / "images" / f"{fid}.jpg")
                        lbl = sess / "labels" / f"{img.stem}.txt"
                        text = remap_label_text(lbl.read_text(encoding="utf-8"), src_classes, classes) \
                            if lbl.exists() else ""
                        (ds / "labels" / f"{fid}.txt").write_text(text, encoding="utf-8")
                        stats["images"] += 1
                        stats["boxes"] += text.count("\n")
                        m = dict(metas.get(img.stem, {}), session=name, id=fid)
                        mf.write(json.dumps(m, ensure_ascii=False) + "\n")
                stats["sessions"] += 1
    (ds / "classes.txt").write_text("\n".join(classes) + "\n", encoding="utf-8")
    stats["classes"] = classes
    return stats


def reviewed_frames(sess: Path) -> set[str] | None:
    """Ảnh đã duyệt của một phiên: cả phiên nếu có file REVIEWED (None = lấy hết), theo review.json nếu có."""
    if (sess / REVIEWED_MARK).exists():
        return None
    try:
        data = json.loads((sess / REVIEW_FILE).read_text(encoding="utf-8"))
        return set(data.get("reviewed", []))
    except (OSError, ValueError, AttributeError):
        return set()


# ---- Bộ dò biển (B3): nhóm biển thô, train riêng ở <dataset>/signs ----
# Ảnh Roboflow/Zalo chỉ khoanh biển (không khoanh xe) nên không gộp chung với model xe: xe sẽ thành "nền".
SIGN_GROUPS = ["no_entry", "no_stop_park", "no_turn", "speed_limit", "prohibit_other", "mandatory", "warning",
               "end_restriction", "sign_other", "no_park", "lane_sign", "aux_plate"]
# no_park (P.131a/b/c, cấm đỗ, vẫn được dừng) thêm ở cuối để chỉ số lớp cũ giữ nguyên. Ảnh Roboflow "Cam dung va do"
# lẫn cả hai loại nên vẫn vào no_stop_park; model chỉ học no_park từ ảnh tự gán P.131*.
# lane_sign (R.411 hướng đi từng làn, R.412 làn riêng theo loại xe, R.415 gộp làn): biển chữ nhật xanh treo trên
# làn, khác hẳn biển hiệu lệnh tròn nên tách nhóm; Roboflow gộp vào "Hieu lenh" nên chỉ học từ ảnh tự gán.
# Tên lớp bộ "Biển báo giao thông Việt Nam (Zalo)" trên Roboflow (CC BY 4.0)
ROBOFLOW_ZALO = {"Cam nguoc chieu": "no_entry", "Cam dung va do": "no_stop_park", "Cam re": "no_turn",
                 "Gioi han toc do": "speed_limit", "Cam con lai": "prohibit_other", "Hieu lenh": "mandatory",
                 "Nguy hiem": "warning"}
IMG_EXT = (".jpg", ".jpeg", ".png")


def sign_group(name: str) -> str | None:
    """Mã biển QCVN (lớp tự gán) hoặc tên lớp Roboflow → nhóm biển; None = không phải biển."""
    if name in ROBOFLOW_ZALO:
        return ROBOFLOW_ZALO[name]
    if name in SIGN_GROUPS:
        return name
    # bảng chữ nhật treo trên làn: phân làn, kể cả bảng ghép tốc độ theo làn (P.127b/c) — khác hẳn biển tốc độ tròn
    if name[:5] in ("R.411", "R.412", "R.415") or name[:6] in ("P.127b", "P.127c"):
        return "lane_sign"
    if name == "P.102":
        return "no_entry"
    if name == "P.130":
        return "no_stop_park"
    if name.startswith("P.131"):
        return "no_park"
    if name.startswith("P.123") or name.startswith("P.124"):
        return "no_turn"
    if name.startswith("P.127"):
        return "speed_limit"
    if name.startswith("DP."):
        return "end_restriction"
    if name.startswith("P."):
        return "prohibit_other"
    if name.startswith("S.5"):   # biển phụ dưới biển chính (giờ, cự ly, loại xe...), khoanh riêng
        return "aux_plate"
    if name.startswith("R."):
        return "mandatory"
    if name.startswith("W."):
        return "warning"
    return None


# ---- Vạch / mũi tên sơn trên mặt đường (QCVN 41:2019 vạch 7.x, 9.3), gán trên trang nhãn, train riêng ở <ds>/marks ----
# Ảnh cũ chưa gán vạch (mũi tên có mà không khoanh) sẽ dạy model "không phải mũi tên", nên chỉ lấy ảnh có ít nhất
# một khung vạch. Không lật ngang khi train (trái/phải đổi nghĩa).
MARKS = {
    "mark_straight": "Mũi tên đi thẳng",
    "mark_left": "Mũi tên rẽ trái",
    "mark_right": "Mũi tên rẽ phải",
    "mark_straight_left": "Mũi tên đi thẳng + rẽ trái",
    "mark_straight_right": "Mũi tên đi thẳng + rẽ phải",
    "mark_uturn": "Mũi tên quay đầu (kể cả rẽ trái + quay đầu)",
    "mark_stop_line": "Vạch dừng (ngang hết làn)",
    "mark_crosswalk": "Vạch người đi bộ (vằn ngựa)",
    "mark_other": "Chữ / số / ký hiệu khác trên mặt đường",
}
MARK_CLASSES = list(MARKS)


def to_mark_labels(text: str, src: list[str]) -> str:
    """Giữ các khung vạch mặt đường của một file nhãn, đổi chỉ số sang MARK_CLASSES."""
    out = []
    for ln in text.splitlines():
        parts = ln.split()
        if len(parts) != 5 or not parts[0].isdigit():
            continue
        i = int(parts[0])
        name = src[i] if i < len(src) else None
        if name in MARKS:
            out.append(" ".join([str(MARK_CLASSES.index(name)), *parts[1:]]))
    return "".join(ln + "\n" for ln in out)


def sync_own_marks(ds: Path) -> int:
    """Chép ảnh tự thu có khung vạch mặt đường sang <ds>/marks (dựng lại mỗi lần train)."""
    md = ds / "marks"
    shutil.rmtree(md / "images", ignore_errors=True)
    shutil.rmtree(md / "labels", ignore_errors=True)
    (md / "images").mkdir(parents=True)
    (md / "labels").mkdir(parents=True)
    (md / "classes.txt").write_text("\n".join(MARK_CLASSES) + "\n", encoding="utf-8")
    src = read_classes(ds / "classes.txt")
    n = 0
    for img in _images(ds / "images"):
        lbl = ds / "labels" / f"{img.stem}.txt"
        text = to_mark_labels(lbl.read_text(encoding="utf-8"), src) if lbl.exists() else ""
        if not text:
            continue
        try:
            os.link(img, md / "images" / img.name)
        except OSError:
            shutil.copy2(img, md / "images" / img.name)
        (md / "labels" / f"{img.stem}.txt").write_text(text, encoding="utf-8")
        n += 1
    return n


# ---- Model xe + đèn (lớp app, YOLOLabel.classes): train ở <ds>/drive, chỉ giữ lớp app ----
DRIVE_CLASSES = ["car", "truck", "bus", "motorcycle", "traffic light"]
# đèn gán theo màu (để đo / train bộ đoán màu); model xe vẫn chỉ học "traffic light"
_LIGHT_BASE = {"light_red": "Đèn đỏ", "light_yellow": "Đèn vàng", "light_green": "Đèn xanh",
               "light_off": "Đèn tắt / không rõ màu"}
# loại đèn (chủ app 21/11): không hậu tố = đèn tròn (mọi hướng / đi thẳng); mũi tên trái / phải / thẳng; đèn thấp riêng
# xe máy. Lớp = light_<màu>[_<loại>], vd light_green_left. Để sau train bộ đoán màu + loại từ ảnh cắt đèn.
LIGHT_TYPES = {"left": "mũi tên rẽ trái", "right": "mũi tên rẽ phải", "straight": "mũi tên đi thẳng",
               "moto": "đèn riêng xe máy", "timer": "đồng hồ đếm ngược"}
LIGHT_COLORS = {**_LIGHT_BASE, **{f"{k}_{t}": f"{v}, {tn}" for k, v in _LIGHT_BASE.items() for t, tn in LIGHT_TYPES.items()}}


def drive_class(name: str) -> str | None:
    if name in DRIVE_CLASSES:
        return name
    return "traffic light" if name in LIGHT_COLORS else None


def to_drive_labels(text: str, src: list[str]) -> str:
    out = []
    for ln in text.splitlines():
        parts = ln.split()
        if len(parts) != 5 or not parts[0].isdigit():
            continue
        i = int(parts[0])
        c = drive_class(src[i]) if i < len(src) else None
        if c is not None:
            out.append(" ".join([str(DRIVE_CLASSES.index(c)), *parts[1:]]))
    return "".join(ln + "\n" for ln in out)


def sync_own_drive(ds: Path) -> int:
    """Dựng <ds>/drive từ ảnh tự thu đã gộp: chỉ lớp app (biển, vạch bỏ; đèn theo màu → traffic light)."""
    dd = ds / "drive"
    shutil.rmtree(dd / "images", ignore_errors=True)
    shutil.rmtree(dd / "labels", ignore_errors=True)
    (dd / "images").mkdir(parents=True)
    (dd / "labels").mkdir(parents=True)
    (dd / "classes.txt").write_text("\n".join(DRIVE_CLASSES) + "\n", encoding="utf-8")
    src = read_classes(ds / "classes.txt")
    n = 0
    for img in _images(ds / "images"):
        lbl = ds / "labels" / f"{img.stem}.txt"
        text = to_drive_labels(lbl.read_text(encoding="utf-8"), src) if lbl.exists() else ""
        try:
            os.link(img, dd / "images" / img.name)
        except OSError:
            shutil.copy2(img, dd / "images" / img.name)
        (dd / "labels" / f"{img.stem}.txt").write_text(text, encoding="utf-8")
        n += 1
    return n


def to_sign_labels(text: str, src: list[str]) -> str:
    """Giữ các khung biển của một file nhãn, đổi lớp sang nhóm biển (SIGN_GROUPS)."""
    out = []
    for ln in text.splitlines():
        parts = ln.split()
        if len(parts) != 5:
            continue
        try:
            i = int(parts[0])
        except ValueError:
            continue
        g = sign_group(src[i]) if 0 <= i < len(src) else None
        if g is not None:
            out.append(" ".join([str(SIGN_GROUPS.index(g)), *parts[1:]]))
    return "".join(ln + "\n" for ln in out)


def _images(d: Path) -> list[Path]:
    return sorted(p for p in d.iterdir() if p.suffix.lower() in IMG_EXT) if d.is_dir() else []


def _prep_signs(sd: Path) -> None:
    (sd / "images").mkdir(parents=True, exist_ok=True)
    (sd / "labels").mkdir(parents=True, exist_ok=True)
    (sd / "classes.txt").write_text("\n".join(SIGN_GROUPS) + "\n", encoding="utf-8")


def import_roboflow(src: Path, ds: Path, tag: str = "rf") -> dict:
    """Nhập bộ Roboflow định dạng YOLO (train/ valid/ test/ + data.yaml) vào <ds>/signs, giữ nguyên chia tập."""
    src, sd = Path(src).expanduser(), ds / "signs"
    names = _yaml_names(src / "data.yaml")
    unknown = [n for n in names if sign_group(n) is None]
    if unknown:
        raise SystemExit(f"Chưa biết map lớp: {unknown}. Thêm vào ROBOFLOW_ZALO trong proto/dataset.py.")
    _prep_signs(sd)
    stats = {"images": 0, "boxes": 0}
    for part in ("train", "valid", "test"):
        for img in _images(src / part / "images"):
            fid = f"{tag}__{part}__{img.stem}"
            shutil.copy2(img, sd / "images" / f"{fid}{img.suffix.lower()}")
            lbl = src / part / "labels" / f"{img.stem}.txt"
            text = to_sign_labels(lbl.read_text(encoding="utf-8"), names) if lbl.exists() else ""
            (sd / "labels" / f"{fid}.txt").write_text(text, encoding="utf-8")
            stats["images"] += 1
            stats["boxes"] += text.count("\n")
    return stats


def _yaml_names(path: Path) -> list[str]:
    """Đọc `names` trong data.yaml của Roboflow (dạng list một dòng hoặc từng dòng `- x` / `0: x`)."""
    import ast
    lines = path.read_text(encoding="utf-8").splitlines()
    for i, ln in enumerate(lines):
        if ln.startswith("names:"):
            rest = ln[len("names:"):].strip()
            if rest:
                return [str(x) for x in ast.literal_eval(rest)]
            out = []
            for sub in lines[i + 1:]:
                if not sub.startswith((" ", "\t", "-")):
                    break
                item = sub.strip().lstrip("-").strip()
                if ":" in item and item.split(":", 1)[0].strip().isdigit():
                    item = item.split(":", 1)[1].strip()
                out.append(item.strip("'\""))
            return out
    raise SystemExit(f"Không thấy names trong {path}")


def sync_own_signs(ds: Path) -> int:
    """Chép ảnh tự thu đã duyệt (trong <ds>/images) sang <ds>/signs, nhãn chỉ giữ biển (ảnh không biển = mẫu nền)."""
    sd = ds / "signs"
    _prep_signs(sd)
    src = read_classes(ds / "classes.txt")
    n = 0
    for img in _images(ds / "images"):
        lbl = ds / "labels" / f"{img.stem}.txt"
        text = to_sign_labels(lbl.read_text(encoding="utf-8"), src) if lbl.exists() else ""
        dst = sd / "images" / img.name
        if not dst.exists():
            try:
                os.link(img, dst)   # cùng ổ: không tốn dung lượng
            except OSError:
                shutil.copy2(img, dst)
        (sd / "labels" / f"{img.stem}.txt").write_text(text, encoding="utf-8")
        n += 1
    return n


def is_val(fid: str, cluster_s: float = CLUSTER_S, fraction: float = VAL_FRACTION) -> bool:
    """Cố định theo (phiên, cụm thời gian): ảnh gần nhau luôn cùng một phía, thêm dữ liệu không đổi chỗ ảnh cũ.
    Ảnh nhập từ Roboflow (<tag>__<train|valid|test>__...) giữ chia tập gốc."""
    sess, _, stem = fid.partition("__")
    part = stem.partition("__")[0]
    if part in ("train", "valid", "test") and "__" in stem:
        return part != "train"
    key = f"{sess}:{int(frame_time(stem) // cluster_s)}"
    h = int(hashlib.sha1(key.encode()).hexdigest()[:8], 16)
    return h / 0xFFFFFFFF < fraction


def split(ds: Path) -> Path:
    files = {p.stem: p.name for p in _images(ds / "images")}
    ids = sorted(files)
    if not ids:
        raise SystemExit(f"Chưa có ảnh trong {ds}/images. Chạy merge trước.")
    val = [i for i in ids if is_val(i)]
    train = [i for i in ids if not is_val(i)]
    if not val:   # ít dữ liệu: vẫn cần tập kiểm tra
        val, train = train[-max(1, len(train) // 7):], train[:-max(1, len(train) // 7)] or train
    for name, part in (("train", train), ("val", val)):
        (ds / f"{name}.txt").write_text("".join(f"{ds / 'images' / files[i]}\n" for i in part), encoding="utf-8")
    classes = read_classes(ds / "classes.txt")
    yaml = ds / "data.yaml"
    names = "\n".join(f"  {i}: {json.dumps(c, ensure_ascii=False)}" for i, c in enumerate(classes))
    yaml.write_text(f"path: {ds}\ntrain: train.txt\nval: val.txt\nnames:\n{names}\n", encoding="utf-8")
    print(f"train {len(train)} ảnh, val {len(val)} ảnh, {len(classes)} lớp → {yaml}")
    return yaml


def train(ds: Path, *, model: str, epochs: int, imgsz: int, batch: int, device: str, name: str,
          task: str = "drive") -> None:
    from ultralytics import YOLO   # nặng, chỉ nạp khi train

    if task == "signs":
        print(f"Ảnh tự thu chép sang bộ biển: {sync_own_signs(ds)}")
        ds = ds / "signs"
    elif task == "drive":
        # chỉ lớp app: lớp biển / vạch trong classes.txt chung không lọt vào model xe
        print(f"Ảnh cho model xe: {sync_own_drive(ds)}")
        ds = ds / "drive"
    elif task == "marks":
        n = sync_own_marks(ds)
        print(f"Ảnh có vạch mặt đường: {n}")
        if n < 20:
            raise SystemExit("Cần ít nhất 20 ảnh có khung vạch / mũi tên (gán trên trang /label) mới train.")
        ds = ds / "marks"
    yaml = split(ds)
    YOLO(model).train(data=str(yaml), epochs=epochs, imgsz=imgsz, batch=batch, device=device,
                      project=str(ds / "runs"), name=name, exist_ok=False,
                      # ảnh camera xe: không lật dọc; lật ngang tắt vì biển rẽ trái/phải sẽ đổi nghĩa
                      fliplr=0.0, flipud=0.0, mosaic=1.0, close_mosaic=10, patience=20)
    extra = {"signs": " signs 736,1280", "marks": " marks 544,960"}.get(task, "")
    print(f"Xong. Export: ./scripts/export_coreml.sh {ds}/runs/{name}/weights/best.pt{extra}")


# ---- So sánh model xe + đèn (vd model gốc COCO với model vừa train) trên cùng tập val ----

def _iou(a: tuple, b: tuple) -> float:
    """IoU hai khung (cx, cy, w, h) chuẩn hoá."""
    ax1, ay1, ax2, ay2 = a[0] - a[2] / 2, a[1] - a[3] / 2, a[0] + a[2] / 2, a[1] + a[3] / 2
    bx1, by1, bx2, by2 = b[0] - b[2] / 2, b[1] - b[3] / 2, b[0] + b[2] / 2, b[1] + b[3] / 2
    iw, ih = max(0.0, min(ax2, bx2) - max(ax1, bx1)), max(0.0, min(ay2, by2) - max(ay1, by1))
    inter = iw * ih
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


def eval_detections(preds: list, gts: dict, classes: list[str], iou: float = 0.5, conf: float = 0.25) -> dict:
    """preds: [(ảnh, lớp, conf, (cx, cy, w, h))]; gts: {ảnh: [(lớp, (cx, cy, w, h))]}.
    Trả về theo lớp: số khung thật, AP50 (nội suy 101 điểm như COCO), precision / recall ở ngưỡng `conf`."""
    out = {}
    for c in classes:
        g = {im: [b for k, b in boxes if k == c] for im, boxes in gts.items()}
        n = sum(len(v) for v in g.values())
        ps = sorted([p for p in preds if p[1] == c], key=lambda p: -p[2])
        used = {im: [False] * len(v) for im, v in g.items()}
        tp = []
        for im, _, _, box in ps:
            best, bi = 0.0, -1
            for j, gb in enumerate(g.get(im, [])):
                o = _iou(box, gb)
                if o > best and not used[im][j]:
                    best, bi = o, j
            if best >= iou:
                used[im][bi] = True
                tp.append(1)
            else:
                tp.append(0)
        prec, rec, ctp = [], [], 0
        for i, t in enumerate(tp):
            ctp += t
            prec.append(ctp / (i + 1))
            rec.append(ctp / n if n else 0.0)
        for i in range(len(prec) - 2, -1, -1):   # đường bao precision
            prec[i] = max(prec[i], prec[i + 1])
        ap = 0.0
        if n:
            for r in [i / 100 for i in range(101)]:
                ap += next((p for p, rr in zip(prec, rec) if rr >= r), 0.0)
            ap /= 101
        k = sum(1 for p in ps if p[2] >= conf)
        tpk = sum(tp[:k])
        out[c] = {"n": n, "ap50": ap, "p": tpk / k if k else 0.0, "r": tpk / n if n else 0.0}
    return out


def _read_gts(images: list[Path], classes: list[str]) -> dict:
    gts = {}
    for img in images:
        lbl = img.parent.parent / "labels" / f"{img.stem}.txt"
        boxes = []
        if lbl.exists():
            for ln in lbl.read_text(encoding="utf-8").splitlines():
                parts = ln.split()
                if len(parts) == 5 and parts[0].isdigit() and int(parts[0]) < len(classes):
                    boxes.append((classes[int(parts[0])], tuple(float(x) for x in parts[1:])))
        gts[img.name] = boxes
    return gts


def drop_small(boxes: list, min_h: float, cls_of=lambda b: b[0], box_of=lambda b: b[1]) -> list:
    """Bỏ xe (không bỏ đèn) có khung thấp hơn `min_h` (tỉ lệ chiều cao ảnh): chủ app chỉ gán xe rõ, gần."""
    return [b for b in boxes if cls_of(b) == "traffic light" or box_of(b)[3] >= min_h]


def compare(ds: Path, models: list[str], imgsz: int = 640, device: str = "mps", min_h: float = 0.05) -> dict:
    """Chấm các model trên tập val của model xe (<ds>/drive/val.txt). Lớp khớp theo tên (COCO có sẵn car, truck,
    bus, motorcycle, traffic light), nên model gốc yolo11n.pt so được trực tiếp với model đã train."""
    from ultralytics import YOLO

    dd = ds / "drive"
    if not (dd / "val.txt").exists():
        sync_own_drive(ds)
        split(dd)
    images = [Path(ln) for ln in (dd / "val.txt").read_text(encoding="utf-8").split()]
    gts = {k: drop_small(v, min_h) for k, v in _read_gts(images, read_classes(dd / "classes.txt")).items()}
    res = {}
    for m in models:
        model = YOLO(m)
        preds = []
        for img in images:
            r = model.predict(str(img), imgsz=imgsz, conf=0.001, device=device, verbose=False)[0]
            for box, c, k in zip(r.boxes.xywhn.tolist(), r.boxes.conf.tolist(), r.boxes.cls.tolist()):
                name = r.names[int(k)]
                if name in DRIVE_CLASSES:
                    preds.append((img.name, name, c, tuple(box)))
        preds = drop_small(preds, min_h, cls_of=lambda p: p[1], box_of=lambda p: p[3])
        res[m] = eval_detections(preds, gts, DRIVE_CLASSES)
    print(f"{len(images)} ảnh val ({dd / 'val.txt'}), chỉ tính xe cao ≥ {min_h:.0%} ảnh. AP50 / P / R (ngưỡng 0,25):")
    print(f"{'lớp':<14}{'khung':>6}  " + "  ".join(f"{Path(m).parent.parent.name or m:>24}" for m in models))
    for c in DRIVE_CLASSES:
        n = res[models[0]][c]["n"]
        cells = "  ".join(f"{res[m][c]['ap50']:>8.2f} {res[m][c]['p']:>6.2f} {res[m][c]['r']:>6.2f}"[:24].rjust(24)
                          for m in models)
        print(f"{c:<14}{n:>6}  {cells}")
    return res


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="python -m proto.dataset", description=__doc__.split("\n")[0])
    ap.add_argument("--dataset", type=Path, default=None, help="mặc định ~/safegap-dataset")
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("merge", help="gộp phiên (.zip hoặc thư mục) vào bộ dữ liệu")
    m.add_argument("sources", nargs="+", type=Path)
    m.add_argument("--all", action="store_true", help="lấy cả phiên chưa có file REVIEWED (nhãn máy)")
    sub.add_parser("split", help="chỉ sinh train.txt / val.txt / data.yaml")
    im = sub.add_parser("import-roboflow", help="nhập bộ biển Roboflow (YOLO, có data.yaml) vào <dataset>/signs")
    im.add_argument("source", type=Path)
    im.add_argument("--tag", default="rf", help="tiền tố tên ảnh, đổi khi nhập thêm bộ khác")
    cp = sub.add_parser("compare", help="chấm model xe + đèn trên tập val (vd yolo11n.pt gốc vs model vừa train)")
    cp.add_argument("models", nargs="*", help="các file .pt; mặc định yolo11n.pt + best.pt mới nhất ở <ds>/drive/runs")
    cp.add_argument("--imgsz", type=int, default=640)
    cp.add_argument("--min-h", type=float, default=0.05,
                    help="bỏ xe (cả nhãn lẫn model) thấp hơn tỉ lệ này của ảnh: chỉ chấm xe rõ, gần (0 = tính hết)")
    cp.add_argument("--device", default="mps")
    t = sub.add_parser("train", help="split rồi train Ultralytics")
    t.add_argument("--model", default="yolo11n.pt", help="điểm bắt đầu (.pt), vd model đã train lần trước")
    t.add_argument("--epochs", type=int, default=80)
    t.add_argument("--task", choices=["drive", "signs", "marks"], default="drive",
                   help="drive = xe + đèn (lớp app); signs = bộ dò biển (nhóm biển, gồm ảnh Roboflow đã nhập); "
                        "marks = vạch / mũi tên mặt đường (ảnh tự gán)")
    t.add_argument("--imgsz", type=int, default=None, help="mặc định 640 (drive) / 1280 (signs: biển rất nhỏ) / 960 (marks)")
    t.add_argument("--batch", type=int, default=16)
    t.add_argument("--device", default="mps")
    t.add_argument("--name", default="safegap")
    a = ap.parse_args(argv)
    ds = (a.dataset or dataset_dir()).expanduser()
    if a.cmd == "merge":
        s = merge(a.sources, ds, only_reviewed=not a.all)
        print(f"{s['sessions']} phiên, {s['images']} ảnh, {s['boxes']} khung → {ds}")
        if s["skipped"]:
            print(f"Bỏ qua (chưa có file {REVIEWED_MARK}, thêm --all nếu muốn): {', '.join(s['skipped'])}")
        print("Lớp:", ", ".join(s["classes"]))
    elif a.cmd == "split":
        split(ds)
    elif a.cmd == "compare":
        models = a.models
        if not models:
            runs = ds / "drive" / "runs"
            found = sorted(runs.glob("*/weights/best.pt"), key=lambda p: p.stat().st_mtime) if runs.is_dir() else []
            models = ["yolo11n.pt"] + ([str(found[-1])] if found else [])
        compare(ds, models, imgsz=a.imgsz, device=a.device, min_h=a.min_h)
    elif a.cmd == "import-roboflow":
        s = import_roboflow(a.source, ds, a.tag)
        print(f"Nhập {s['images']} ảnh, {s['boxes']} khung biển → {ds / 'signs'}")
    else:
        imgsz = a.imgsz or {"signs": 1280, "marks": 960}.get(a.task, 640)
        train(ds, model=a.model, epochs=a.epochs, imgsz=imgsz, batch=a.batch, device=a.device, name=a.name,
              task=a.task)


if __name__ == "__main__":
    main()
