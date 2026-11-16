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
  5. Export Core ML: ./scripts/export_coreml.sh ~/safegap-dataset/runs/<tên>/weights/best.pt

Bộ dò biển (B3), train riêng, lớp = nhóm biển (SIGN_GROUPS):
  uv run python -m proto.dataset import-roboflow ~/datasets/vn-signs     # bộ Zalo trên Roboflow, YOLOv11
  uv run python -m proto.dataset train --task signs --batch 8 --name signs
  (ảnh tự thu đã duyệt tự được thêm vào, mã biển QCVN gom về nhóm; ảnh không biển làm mẫu nền)

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
               "end_restriction", "sign_other"]
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
    if name == "P.102":
        return "no_entry"
    if name == "P.130" or name.startswith("P.131"):
        return "no_stop_park"
    if name.startswith("P.123") or name.startswith("P.124"):
        return "no_turn"
    if name.startswith("P.127"):
        return "speed_limit"
    if name.startswith("DP."):
        return "end_restriction"
    if name.startswith("P."):
        return "prohibit_other"
    if name.startswith("R."):
        return "mandatory"
    if name.startswith("W."):
        return "warning"
    return None


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
    yaml = split(ds)
    YOLO(model).train(data=str(yaml), epochs=epochs, imgsz=imgsz, batch=batch, device=device,
                      project=str(ds / "runs"), name=name, exist_ok=False,
                      # ảnh camera xe: không lật dọc; lật ngang tắt vì biển rẽ trái/phải sẽ đổi nghĩa
                      fliplr=0.0, flipud=0.0, mosaic=1.0, close_mosaic=10, patience=20)
    print(f"Xong. Export: ./scripts/export_coreml.sh {ds}/runs/{name}/weights/best.pt")


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
    t = sub.add_parser("train", help="split rồi train Ultralytics")
    t.add_argument("--model", default="yolo11n.pt", help="điểm bắt đầu (.pt), vd model đã train lần trước")
    t.add_argument("--epochs", type=int, default=80)
    t.add_argument("--task", choices=["drive", "signs"], default="drive",
                   help="drive = xe + đèn (lớp app); signs = bộ dò biển (nhóm biển, gồm ảnh Roboflow đã nhập)")
    t.add_argument("--imgsz", type=int, default=None, help="mặc định 640 (drive) / 1280 (signs: biển rất nhỏ)")
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
    elif a.cmd == "import-roboflow":
        s = import_roboflow(a.source, ds, a.tag)
        print(f"Nhập {s['images']} ảnh, {s['boxes']} khung biển → {ds / 'signs'}")
    else:
        imgsz = a.imgsz or (1280 if a.task == "signs" else 640)
        train(ds, model=a.model, epochs=a.epochs, imgsz=imgsz, batch=a.batch, device=a.device, name=a.name,
              task=a.task)


if __name__ == "__main__":
    main()
