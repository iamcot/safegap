"""Gộp ảnh tự thu trên xe thành bộ dữ liệu YOLO và train trên Mac (docs/DRIVER_ASSIST.md, B2/B3).

Luồng mỗi tối:
  1. App > Cài đặt > Phiên thu dữ liệu > chia sẻ .zip sang Mac (AirDrop).
  2. Gán nhãn trong CVAT / Label Studio (mở thẳng thư mục phiên: images/ + labels/ + classes.txt, định dạng YOLO).
     Thêm lớp mới (biển báo...) vào cuối classes.txt; xuất lại YOLO đè lên labels/.
     Xong phiên nào thì tạo file rỗng `REVIEWED` trong thư mục phiên đó (nhãn máy chưa sửa chỉ dạy lại lỗi cũ).
  3. Gộp:   uv run python -m proto.dataset merge ~/Downloads/capture_*.zip ~/Downloads/capture_2026*/
  4. Train: uv run python -m proto.dataset train --epochs 80          (mặc định --device mps, từ yolo11n.pt)
  5. Export Core ML: ./scripts/export_coreml.sh ~/safegap-dataset/runs/<tên>/weights/best.pt

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
                if only_reviewed and not (sess / REVIEWED_MARK).exists():
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
                with meta_out.open("a", encoding="utf-8") as mf:
                    for img in sorted((sess / "images").glob("*.jpg")):
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


def is_val(fid: str, cluster_s: float = CLUSTER_S, fraction: float = VAL_FRACTION) -> bool:
    """Cố định theo (phiên, cụm thời gian): ảnh gần nhau luôn cùng một phía, thêm dữ liệu không đổi chỗ ảnh cũ."""
    sess, _, stem = fid.partition("__")
    key = f"{sess}:{int(frame_time(stem) // cluster_s)}"
    h = int(hashlib.sha1(key.encode()).hexdigest()[:8], 16)
    return h / 0xFFFFFFFF < fraction


def split(ds: Path) -> Path:
    ids = sorted(p.stem for p in (ds / "images").glob("*.jpg"))
    if not ids:
        raise SystemExit(f"Chưa có ảnh trong {ds}/images. Chạy merge trước.")
    val = [i for i in ids if is_val(i)]
    train = [i for i in ids if not is_val(i)]
    if not val:   # ít dữ liệu: vẫn cần tập kiểm tra
        val, train = train[-max(1, len(train) // 7):], train[:-max(1, len(train) // 7)] or train
    for name, part in (("train", train), ("val", val)):
        (ds / f"{name}.txt").write_text("".join(f"{ds / 'images' / i}.jpg\n" for i in part), encoding="utf-8")
    classes = read_classes(ds / "classes.txt")
    yaml = ds / "data.yaml"
    names = "\n".join(f"  {i}: {json.dumps(c, ensure_ascii=False)}" for i, c in enumerate(classes))
    yaml.write_text(f"path: {ds}\ntrain: train.txt\nval: val.txt\nnames:\n{names}\n", encoding="utf-8")
    print(f"train {len(train)} ảnh, val {len(val)} ảnh, {len(classes)} lớp → {yaml}")
    return yaml


def train(ds: Path, *, model: str, epochs: int, imgsz: int, batch: int, device: str, name: str) -> None:
    from ultralytics import YOLO   # nặng, chỉ nạp khi train

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
    t = sub.add_parser("train", help="split rồi train Ultralytics")
    t.add_argument("--model", default="yolo11n.pt", help="điểm bắt đầu (.pt), vd model đã train lần trước")
    t.add_argument("--epochs", type=int, default=80)
    t.add_argument("--imgsz", type=int, default=640)
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
    else:
        train(ds, model=a.model, epochs=a.epochs, imgsz=a.imgsz, batch=a.batch, device=a.device, name=a.name)


if __name__ == "__main__":
    main()
