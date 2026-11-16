"""Trang gán nhãn ảnh tự thu trên xe (docs/DRIVER_ASSIST.md, B2): http://127.0.0.1:8501/label

    uv run python -m proto.viewer      # rồi mở /label (hoặc bấm "Gán nhãn" trên viewer)

- Thả file .zip phiên thu (chia sẻ từ app) vào ~/safegap-dataset/inbox/ hoặc kéo thả lên trang: tự giải nén.
- Ảnh có sẵn khung máy khoanh (xe, đèn). Sửa / thêm khung, chọn lớp (biển theo mã QCVN), bấm Duyệt.
  Chỉ ảnh đã duyệt mới vào bộ train (ghi trong <phiên>/review.json).
- Nút "Gộp + Train" chạy `proto.dataset merge` (mọi phiên trong inbox) rồi `train` (mps) ở nền, xem log ngay trên trang.

Danh sách lớp = lớp của app (YOLOLabel.classes) + mã biển trong config/signs_vn.json + "sign_other" (biển khác).
Lớp mới chỉ thêm vào cuối, không đổi chỉ số cũ; nhãn của phiên được đổi chỉ số theo tên khi mở.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import zipfile
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

from . import dataset as D

ROOT = Path(__file__).resolve().parent.parent
HTML = Path(__file__).with_name("labeler.html")
APP_CLASSES = ["car", "truck", "bus", "motorcycle", "traffic light"]   # = YOLOLabel.classes trong app
OTHER_SIGN = "sign_other"


def sign_names() -> dict[str, str]:
    try:
        data = json.loads((ROOT / "config" / "signs_vn.json").read_text(encoding="utf-8"))
        return {code: s.get("name", code) for code, s in data["signs"].items()}
    except (OSError, ValueError, KeyError):
        return {}


def class_list(ds: Path) -> list[str]:
    """Lớp chung: những gì bộ dữ liệu đã có (giữ chỉ số), thêm lớp app + biển còn thiếu ở cuối."""
    return D.merge_classes(D.read_classes(ds / "classes.txt"),
                           APP_CLASSES + list(sign_names()) + [OTHER_SIGN])


def _safe(name: str) -> str:
    if not name or "/" in name or "\\" in name or name.startswith("."):
        raise HTTPException(400, f"Tên không hợp lệ: {name}")
    return name


def unpack_inbox(inbox: Path) -> None:
    for z in sorted(inbox.glob("*.zip")):
        dest = inbox / z.stem
        if dest.exists():
            continue
        with zipfile.ZipFile(z) as zf:
            names = zf.namelist()
            if any(n.startswith("/") or ".." in Path(n).parts for n in names):
                continue
            # zip của app chứa sẵn thư mục capture_xxx/ ở gốc
            nested = all(n.startswith(z.stem + "/") for n in names)
            zf.extractall(inbox if nested else dest)


class Box(BaseModel):
    cls: str
    cx: float
    cy: float
    w: float
    h: float


class SaveReq(BaseModel):
    session: str
    frame: str
    boxes: list[Box]
    reviewed: bool = True


class TrainReq(BaseModel):
    epochs: int = 80
    model: str = "yolo11n.pt"
    merge_only: bool = False
    task: str = "drive"


def make_router(ds_dir: Optional[Path] = None) -> APIRouter:
    r = APIRouter()
    job: dict = {"proc": None, "log": None}

    def ds() -> Path:
        return (ds_dir or D.dataset_dir()).expanduser()

    def inbox() -> Path:
        p = ds() / "inbox"
        p.mkdir(parents=True, exist_ok=True)
        return p

    def session_dir(name: str) -> Path:
        d = inbox() / _safe(name)
        if not (d / "images").is_dir():
            raise HTTPException(404, f"Không thấy phiên {name}")
        return d

    def reviewed(d: Path) -> set[str]:
        try:
            return set(json.loads((d / D.REVIEW_FILE).read_text(encoding="utf-8")).get("reviewed", []))
        except (OSError, ValueError, AttributeError):
            return set()

    def sync_classes(d: Path, classes: list[str]) -> None:
        """Đưa nhãn của phiên về danh sách lớp chung (đổi chỉ số theo tên) một lần."""
        src = D.read_classes(d / "classes.txt")
        if src == classes:
            return
        for f in (d / "labels").glob("*.txt"):
            f.write_text(D.remap_label_text(f.read_text(encoding="utf-8"), src, D.merge_classes(classes, src)),
                         encoding="utf-8")
        (d / "classes.txt").write_text("\n".join(D.merge_classes(classes, src)) + "\n", encoding="utf-8")

    @r.get("/label", response_class=HTMLResponse)
    def page():
        return HTML.read_text(encoding="utf-8")

    @r.get("/api/label/sessions")
    def sessions():
        box = inbox()
        unpack_inbox(box)
        out = []
        for d in sorted((p for p in box.iterdir() if (p / "images").is_dir()), reverse=True):
            n = sum(1 for _ in (d / "images").glob("*.jpg"))
            out.append({"name": d.name, "images": n, "reviewed": len(reviewed(d))})
        names = sign_names()
        return {"sessions": out, "classes": class_list(ds()), "inbox": str(box),
                "names": {**names, OTHER_SIGN: "Biển khác (chưa có trong danh sách)"}}

    @r.post("/api/label/upload")
    async def upload(request: Request, name: str):
        safe = Path(name).name
        if not safe.endswith(".zip"):
            raise HTTPException(400, "Chỉ nhận file .zip của app")
        dest = inbox() / safe
        with open(dest, "wb") as f:
            async for chunk in request.stream():
                f.write(chunk)
        unpack_inbox(inbox())
        return {"ok": True}

    @r.get("/api/label/frames")
    def frames(session: str):
        d = session_dir(session)
        classes = class_list(ds())
        sync_classes(d, classes)
        meta = {}
        if (d / "meta.jsonl").exists():
            for ln in (d / "meta.jsonl").read_text(encoding="utf-8").splitlines():
                try:
                    m = json.loads(ln)
                    meta[Path(m["file"]).stem] = {k: m.get(k) for k in ("speedKmh", "light", "time")}
                except (ValueError, KeyError, TypeError):
                    continue
        done = reviewed(d)
        return {"frames": [{"id": p.stem, "reviewed": p.stem in done, **meta.get(p.stem, {})}
                           for p in sorted((d / "images").glob("*.jpg"))],
                "classes": D.read_classes(d / "classes.txt")}

    @r.get("/api/label/image")
    def image(session: str, frame: str):
        p = session_dir(session) / "images" / f"{_safe(frame)}.jpg"
        if not p.is_file():
            raise HTTPException(404, "Không thấy ảnh")
        return FileResponse(p, media_type="image/jpeg")

    @r.get("/api/label/boxes")
    def boxes(session: str, frame: str):
        d = session_dir(session)
        classes = D.read_classes(d / "classes.txt")
        p = d / "labels" / f"{_safe(frame)}.txt"
        out = []
        if p.exists():
            for ln in p.read_text(encoding="utf-8").splitlines():
                parts = ln.split()
                try:
                    i, vals = int(parts[0]), [float(v) for v in parts[1:5]]
                except (ValueError, IndexError):
                    continue
                if 0 <= i < len(classes) and len(vals) == 4:
                    out.append({"cls": classes[i], "cx": vals[0], "cy": vals[1], "w": vals[2], "h": vals[3]})
        return {"boxes": out}

    @r.post("/api/label/save")
    def save(req: SaveReq):
        d = session_dir(req.session)
        frame = _safe(req.frame)
        if not (d / "images" / f"{frame}.jpg").is_file():
            raise HTTPException(404, "Không thấy ảnh")
        classes = D.read_classes(d / "classes.txt")
        new = [b.cls for b in req.boxes if b.cls not in classes]
        if new:
            classes = D.merge_classes(classes, new)
            (d / "classes.txt").write_text("\n".join(classes) + "\n", encoding="utf-8")
        lines = []
        for b in req.boxes:
            x1, y1 = max(0.0, b.cx - b.w / 2), max(0.0, b.cy - b.h / 2)
            x2, y2 = min(1.0, b.cx + b.w / 2), min(1.0, b.cy + b.h / 2)
            if x2 - x1 < 1e-3 or y2 - y1 < 1e-3:
                continue
            lines.append(f"{classes.index(b.cls)} {(x1 + x2) / 2:.6f} {(y1 + y2) / 2:.6f} {x2 - x1:.6f} {y2 - y1:.6f}")
        (d / "labels").mkdir(exist_ok=True)
        (d / "labels" / f"{frame}.txt").write_text("".join(ln + "\n" for ln in lines), encoding="utf-8")
        done = reviewed(d)
        (done.add if req.reviewed else done.discard)(frame)
        (d / D.REVIEW_FILE).write_text(json.dumps({"reviewed": sorted(done)}), encoding="utf-8")
        return {"reviewed": len(done)}

    @r.post("/api/label/train")
    def train(req: TrainReq):
        p = job["proc"]
        if p is not None and p.poll() is None:
            raise HTTPException(409, "Đang chạy rồi")
        root = ds()
        log = root / "train.log"
        sessions_ = [str(x) for x in inbox().iterdir() if (x / "images").is_dir()]
        signs = req.task == "signs"
        if not sessions_ and (req.merge_only or not signs):
            raise HTTPException(400, "Inbox chưa có phiên nào")
        py = sys.executable
        # bộ biển train được chỉ với ảnh Roboflow đã nhập, chưa cần phiên tự thu
        cmd = (f"{_q(py)} -m proto.dataset --dataset {_q(str(root))} merge " + " ".join(_q(s) for s in sessions_)
               if sessions_ else "true")
        if not req.merge_only:
            cmd += (f" && {_q(py)} -m proto.dataset --dataset {_q(str(root))} train"
                    f" --task {'signs' if req.task == 'signs' else 'drive'} --epochs {int(req.epochs)}"
                    f" --model {_q(req.model)}{' --batch 8' if signs else ''} --name {'signs' if req.task == 'signs' else 'drive'}_$(date +%Y%m%d_%H%M)")
        fh = open(log, "w", encoding="utf-8")
        job["proc"] = subprocess.Popen(["/bin/sh", "-c", cmd], cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT,
                                       env={**os.environ, "PYTHONUNBUFFERED": "1"})
        job["log"] = log
        threading.Thread(target=lambda: (job["proc"].wait(), fh.close()), daemon=True).start()
        return {"started": True}

    @r.get("/api/label/train")
    def train_status():
        p, log = job["proc"], job["log"]
        tail = ""
        if log is not None and Path(log).exists():
            tail = "\n".join(Path(log).read_text(encoding="utf-8", errors="replace")
                             .replace("\r", "\n").splitlines()[-40:])
        return {"running": p is not None and p.poll() is None,
                "code": None if p is None else p.poll(), "log": tail}

    return r


def _q(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"
