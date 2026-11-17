"""Trang gán nhãn ảnh tự thu trên xe (docs/DRIVER_ASSIST.md, B2): http://127.0.0.1:8501/label

    uv run python -m proto.viewer      # rồi mở /label (hoặc bấm "Gán nhãn" trên viewer)

- Thả file .zip phiên thu (chia sẻ từ app) vào ~/safegap-dataset/inbox/ hoặc kéo thả lên trang: tự giải nén.
- Ảnh có sẵn khung máy khoanh (xe, đèn). Sửa / thêm khung, chọn lớp (biển theo mã QCVN), bấm Duyệt.
  Chỉ ảnh đã duyệt mới vào bộ train (ghi trong <phiên>/review.json).
- Khung gợi ý: model biển / xe mới nhất đã train trên Mac (runs/*/weights/best.pt) tự khoanh sẵn ảnh chưa duyệt
  (nét đứt), người gán chỉ sửa / xoá / thêm rồi duyệt.
- Nút "Gộp + Train" chạy `proto.dataset merge` (mọi phiên trong inbox) rồi `train` (mps) ở nền, xem log ngay trên trang.

Danh sách lớp = lớp của app (YOLOLabel.classes) + mã biển trong config/signs_vn.json + "sign_other" (biển khác).
Lớp mới chỉ thêm vào cuối, không đổi chỉ số cũ; nhãn của phiên được đổi chỉ số theo tên khi mở.
"""
from __future__ import annotations

import json
import shutil
import threading
import os
import re
import subprocess
import sys
import time
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
# Model biển chỉ biết nhóm biển: nhóm có một mã QCVN chính thì gợi ý mã đó, nhóm còn lại giữ tên nhóm
# (proto.dataset.sign_group hiểu cả hai; người gán đổi sang mã cụ thể nếu muốn).
GROUP_CODE = {"no_entry": "P.102", "no_stop_park": "P.130", "no_park": "P.131a", "speed_limit": "P.127",
              "sign_other": OTHER_SIGN}
GROUP_NAMES = {"no_turn": "Nhóm cấm rẽ / quay đầu (chưa rõ mã)", "prohibit_other": "Nhóm biển cấm khác (chưa rõ mã)",
               "mandatory": "Nhóm biển hiệu lệnh (xanh tròn)", "warning": "Nhóm biển nguy hiểm (tam giác vàng)",
               "end_restriction": "Nhóm biển hết cấm", "lane_sign": "Nhóm biển phân làn (chưa rõ mã)"}
SUGGEST_CONF = 0.25


def sign_names() -> dict[str, str]:
    """Biển có luật (signs_vn.json) + biển hay gặp chỉ để gán nhãn (sign_catalog_vn.json)."""
    out: dict[str, str] = {}
    try:
        data = json.loads((ROOT / "config" / "signs_vn.json").read_text(encoding="utf-8"))
        out.update({code: s.get("name", code) for code, s in data["signs"].items()})
    except (OSError, ValueError, KeyError):
        pass
    try:
        cat = json.loads((ROOT / "config" / "sign_catalog_vn.json").read_text(encoding="utf-8"))
        out.update({code: name for code, name in cat["signs"].items() if code not in out})
    except (OSError, ValueError, KeyError):
        pass
    return out


def class_list(ds: Path) -> list[str]:
    """Lớp chung: những gì bộ dữ liệu đã có (giữ chỉ số), thêm lớp app + biển còn thiếu ở cuối."""
    return D.merge_classes(D.read_classes(ds / "classes.txt"),
                           APP_CLASSES + list(sign_names()) + [OTHER_SIGN] + list(GROUP_NAMES) + D.MARK_CLASSES)


def latest_weights(runs: Path) -> Optional[Path]:
    """best.pt mới nhất trong <runs>/*/weights/."""
    found = sorted(runs.glob("*/weights/best.pt"), key=lambda p: p.stat().st_mtime) if runs.is_dir() else []
    return found[-1] if found else None


def suggest_class(name: str, task: str) -> Optional[str]:
    """Tên lớp model → lớp trang gán nhãn; None = bỏ (lớp xe COCO khác, lớp lạ)."""
    if task == "signs":
        return GROUP_CODE.get(name, name if name in GROUP_NAMES else None)
    if task == "marks":
        return name if name in D.MARKS else None
    return name if name in APP_CLASSES else None


def slash_code(pixels) -> Optional[str]:
    """Biển tròn nền xanh viền đỏ: hai vạch chéo (X) = P.130, một vạch = P.131a; None = không chắc.
    `pixels`: list (r, g, b, u, v), rgb 0..1, (u, v) 0..1 theo khung. Giống NoStopParkClassifier trong app."""
    import colorsys
    d1, d2 = [0, 0], [0, 0]
    for r, g, b, u, v in pixels:
        rad = ((u - 0.5) ** 2 + (v - 0.5) ** 2) ** 0.5
        if not 0.1 < rad < 0.36:
            continue
        h, s, val = colorsys.rgb_to_hsv(r, g, b)
        red = (h * 360 < 20 or h * 360 > 335) and s > 0.35 and val > 0.25
        if abs(u - v) < 0.09:
            d1[0] += red
            d1[1] += 1
        if abs(u + v - 1) < 0.09:
            d2[0] += red
            d2[1] += 1
    if d1[1] < 4 or d2[1] < 4:
        return None
    f1, f2 = d1[0] / d1[1], d2[0] / d2[1]
    if f1 >= 0.3 and f2 >= 0.3:
        return "P.130"
    if max(f1, f2) >= 0.3 and min(f1, f2) <= 0.15:
        return "P.131a"
    return None


def crop_pixels(img, cx: float, cy: float, w: float, h: float, n: int = 24) -> list:
    """Lưới n×n điểm trong khung (ảnh PIL RGB, khung chuẩn hoá) → (r, g, b, u, v)."""
    W, H = img.size
    out = []
    for j in range(n):
        for i in range(n):
            u, v = (i + 0.5) / n, (j + 0.5) / n
            x = min(W - 1, max(0, int((cx - w / 2 + u * w) * W)))
            y = min(H - 1, max(0, int((cy - h / 2 + v * h) * H)))
            r, g, b = img.getpixel((x, y))[:3]
            out.append((r / 255, g / 255, b / 255, u, v))
    return out


def _iou(a: dict, b: dict) -> float:
    ax1, ay1, ax2, ay2 = a["cx"] - a["w"] / 2, a["cy"] - a["h"] / 2, a["cx"] + a["w"] / 2, a["cy"] + a["h"] / 2
    bx1, by1, bx2, by2 = b["cx"] - b["w"] / 2, b["cy"] - b["h"] / 2, b["cx"] + b["w"] / 2, b["cy"] + b["h"] / 2
    iw, ih = max(0.0, min(ax2, bx2) - max(ax1, bx1)), max(0.0, min(ay2, by2) - max(ay1, by1))
    inter = iw * ih
    union = a["w"] * a["h"] + b["w"] * b["h"] - inter
    return inter / union if union > 0 else 0.0


def new_suggestions(existing: list[dict], proposed: list[dict], iou: float = 0.4) -> list[dict]:
    """Khung gợi ý chưa trùng khung đã có (cùng loại biển / xe), khung tin cậy cao trước."""
    def kind(c: str) -> str:
        return "vehicle" if c in APP_CLASSES else ("mark" if c in D.MARKS else "sign")
    out: list[dict] = []
    for p in sorted(proposed, key=lambda b: -b.get("conf", 0)):
        if any(kind(e["cls"]) == kind(p["cls"]) and _iou(e, p) > iou for e in existing + out):
            continue
        out.append(p)
    return out


class Suggester:
    """Chạy model đã train (Ultralytics) trên một ảnh. Nạp chậm lần đầu, giữ trong bộ nhớ, đổi khi có best.pt mới."""

    def __init__(self, ds: Path):
        self.ds = ds
        self.lock = threading.Lock()
        self.cache: dict[str, tuple[Path, object]] = {}

    def weights(self) -> dict[str, Optional[Path]]:
        # model xe COCO gốc giống hệt model trên app (nhãn máy đã có): chỉ gợi ý xe khi đã tự train
        return {"signs": latest_weights(self.ds / "signs" / "runs"), "drive": latest_weights(self.ds / "runs"),
                "marks": latest_weights(self.ds / "marks" / "runs")}

    def _model(self, task: str, w: Path):
        hit = self.cache.get(task)
        if hit and hit[0] == w:
            return hit[1]
        from ultralytics import YOLO
        m = YOLO(str(w))
        self.cache[task] = (w, m)
        return m

    def __call__(self, img: Path) -> list[dict]:
        out: list[dict] = []
        pil = None
        with self.lock:
            for task, w in self.weights().items():
                if w is None:
                    continue
                m = self._model(task, w)
                res = m.predict(str(img), imgsz={"signs": 1280, "marks": 960}.get(task, 640), conf=SUGGEST_CONF, verbose=False)[0]
                names = res.names
                for (cx, cy, bw, bh), c, k in zip(res.boxes.xywhn.tolist(), res.boxes.conf.tolist(),
                                                   res.boxes.cls.tolist()):
                    cls = suggest_class(names[int(k)], task)
                    if cls == "P.130":   # nhóm cũ gộp cả cấm đỗ: đếm vạch đỏ để tách P.131a
                        try:
                            if pil is None:
                                from PIL import Image
                                pil = Image.open(img).convert("RGB")
                            cls = slash_code(crop_pixels(pil, cx, cy, bw, bh)) or cls
                        except (OSError, ImportError):
                            pass
                    if cls:
                        out.append({"cls": cls, "cx": cx, "cy": cy, "w": bw, "h": bh, "conf": round(c, 3)})
        return out


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


def make_router(ds_dir: Optional[Path] = None, suggester=None) -> APIRouter:
    r = APIRouter()
    job: dict = {"proc": None, "suggester": suggester}

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
                "names": {**names, OTHER_SIGN: "Biển khác (chưa có trong danh sách)", **GROUP_NAMES, **D.MARKS}}

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
                    meta[Path(m["file"]).stem] = {k: m.get(k) for k in ("speedKmh", "light", "time", "signs")}
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

    def get_suggester():
        if job["suggester"] is None:
            job["suggester"] = Suggester(ds())
        return job["suggester"]

    @r.get("/api/label/suggest/models")
    def suggest_models():
        sg = get_suggester()
        w = sg.weights() if hasattr(sg, "weights") else {}
        return {k: (str(v) if v else None) for k, v in w.items()}

    @r.post("/api/label/suggest")
    def suggest(req: SaveReq):
        """Khung model đề xuất cho ảnh, bỏ những khung trùng khung đang có trên trang (req.boxes)."""
        d = session_dir(req.session)
        img = d / "images" / f"{_safe(req.frame)}.jpg"
        if not img.is_file():
            raise HTTPException(404, "Không thấy ảnh")
        try:
            proposed = get_suggester()(img)
        except ImportError:
            raise HTTPException(500, "Chưa cài ultralytics (uv sync)")
        return {"boxes": new_suggestions([b.model_dump() for b in req.boxes], proposed)}

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

    # Trạng thái train ghi ra file (<dataset>/train.log + train.json) và tiến trình train tách nhóm riêng:
    # tắt / mở lại viewer (Ctrl+C) không giết train, mở lại trang vẫn thấy tiến độ.
    def train_state() -> dict:
        try:
            return json.loads((ds() / "train.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def exit_code(text: str) -> Optional[int]:
        m = re.search(r"__EXIT__ (\d+)", text)
        return int(m.group(1)) if m else None

    def alive(pid: Optional[int]) -> bool:
        if not pid:
            return False
        try:
            os.kill(pid, 0)
            return True
        except (OSError, ProcessLookupError):
            return False

    def read_log() -> str:
        log = ds() / "train.log"
        return log.read_text(encoding="utf-8", errors="replace") if log.exists() else ""

    @r.post("/api/label/train")
    def train(req: TrainReq):
        st = train_state()
        if alive(st.get("pid")) and exit_code(read_log()) is None:
            raise HTTPException(409, "Đang chạy rồi")
        root = ds()
        root.mkdir(parents=True, exist_ok=True)
        log = root / "train.log"
        sessions_ = [str(x) for x in inbox().iterdir() if (x / "images").is_dir()]
        task = req.task if req.task in ("drive", "signs", "marks") else "drive"
        signs = task == "signs"
        if not sessions_ and (req.merge_only or not signs):
            raise HTTPException(400, "Inbox chưa có phiên nào")
        py = sys.executable
        # bộ biển train được chỉ với ảnh Roboflow đã nhập, chưa cần phiên tự thu
        cmd = (f"{_q(py)} -m proto.dataset --dataset {_q(str(root))} merge " + " ".join(_q(s) for s in sessions_)
               if sessions_ else "true")
        if not req.merge_only:
            cmd += (f" && {_q(py)} -m proto.dataset --dataset {_q(str(root))} train"
                    f" --task {task} --epochs {int(req.epochs)}"
                    f" --model {_q(req.model)}{' --batch 8' if signs else ''}"
                    f" --name {task}_$(date +%Y%m%d_%H%M)")
        # caffeinate (macOS): giữ máy không ngủ tới khi train xong
        wrap = f"({cmd}); echo \"__EXIT__ $?\""
        argv = ["caffeinate", "-i", "/bin/sh", "-c", wrap] if shutil.which("caffeinate") else ["/bin/sh", "-c", wrap]
        with open(log, "w", encoding="utf-8") as fh:
            p = subprocess.Popen(argv, cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT, start_new_session=True,
                                 env={**os.environ, "PYTHONUNBUFFERED": "1"})
        (root / "train.json").write_text(json.dumps({"pid": p.pid, "t0": time.time(), "task": req.task}),
                                         encoding="utf-8")
        job["proc"] = p   # giữ để thu dọn tiến trình con khi xong
        return {"started": True}

    @r.get("/api/label/train")
    def train_status():
        if job["proc"] is not None:
            job["proc"].poll()   # thu dọn tiến trình con đã xong (tránh zombie)
        st = train_state()
        text = read_log()
        code = exit_code(text)
        running = code is None and alive(st.get("pid"))
        if not st and not text:
            return {"running": False, "code": None, "log": "", "summary": {}}
        if code is None and not running:
            code = -1   # tiến trình mất mà không ghi mã thoát (máy khởi động lại...)
        summary = summarize_log(text, started=st.get("t0"), now=time.time() if running else None)
        lines = [ln for ln in _ANSI.sub("", text).replace("\r", "\n").splitlines() if not ln.startswith("__EXIT__")]
        return {"running": running, "code": code, "log": "\n".join(lines[-30:]), "summary": summary}

    return r


_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_EPOCH = re.compile(r"^\s*(\d+)/(\d+)\s+[\d.]+G\b.*?(\d+)/(\d+)\s", re.M)
_RUN_DIR = re.compile(r"Logging results to (.+?)\s*$", re.M)


def summarize_log(text: str, *, started: Optional[float] = None, now: Optional[float] = None) -> dict:
    """Tóm tắt log Ultralytics cho người xem: epoch đang chạy, % tổng, còn bao lâu, mAP50 theo epoch (results.csv)."""
    clean = _ANSI.sub("", text).replace("\r", "\n")
    out: dict = {"stage": "merge" if "phiên" in clean and "Epoch" not in clean else None}
    m = None
    for m in _EPOCH.finditer(clean):
        pass
    if m:
        ep, total, step, steps = (int(x) for x in m.groups())
        frac = min(1.0, ((ep - 1) + step / max(1, steps)) / max(1, total))
        out.update(stage="train", epoch=ep, epochs=total, step=step, steps=steps, progress=round(frac, 4))
        if started and now and frac > 0.002:
            out["eta_s"] = round((now - started) * (1 - frac) / frac)
    rd = None
    for rd in _RUN_DIR.finditer(clean):
        pass
    if rd:
        run = Path(rd.group(1).strip())
        out["run"] = str(run)
        csv = run / "results.csv"
        if csv.exists():
            rows = [ln.split(",") for ln in csv.read_text(encoding="utf-8").splitlines()]
            if len(rows) > 1:
                head = [h.strip() for h in rows[0]]
                try:
                    i50 = head.index("metrics/mAP50(B)")
                    ie = head.index("epoch")
                    hist = [(int(float(r[ie])), float(r[i50])) for r in rows[1:] if len(r) > i50]
                    out["map50"] = [round(v, 4) for _, v in hist]
                    out["best_map50"] = max(v for _, v in hist)
                except (ValueError, IndexError):
                    pass
    if "Xong. Export:" in clean:
        out["stage"] = "done"
        out["export"] = clean.split("Xong. Export:")[-1].strip().splitlines()[0]
    return out


def _q(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"
