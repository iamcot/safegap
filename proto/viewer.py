"""SafeGap viewer – trang web chạy local để xem thuật toán trên video đã quay.

    uv run python -m proto.viewer            # mở http://127.0.0.1:8501

- Video phát thẳng trong trình duyệt (mượt, đúng fps gốc). Box, ROI, D, màu cảnh báo vẽ lên canvas phía trên.
- YOLO chạy nền, bắt đầu từ chỗ đang xem: kéo tới đâu nhận diện tới đó, không phải chờ chạy hết clip.
  Kết quả lưu vào out/<tên>_dets.json, mở lại clip là có sẵn, đoạn nào đã nhận diện thì không chạy lại.
- Chỉnh f, bề rộng xe, ROI, ngưỡng ở thanh bên: kết quả tính lại ngay trên detection đã có (không chạy lại YOLO).
"""
from __future__ import annotations

import argparse
import json
import threading
import time
from contextlib import asynccontextmanager
import webbrowser
from pathlib import Path
from typing import Callable, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel

from . import config, detcache
from .lane import roi_to_pixels
from .replay import IncrementalReplay
from .speed import SpeedTrack

ROOT = Path(__file__).resolve().parent.parent
CLIPS_DIR = ROOT / "data" / "clips"
OUT_DIR = ROOT / "out"
UPLOAD_DIR = OUT_DIR / "uploads"
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}
HTML = Path(__file__).with_name("viewer.html")
SAVE_EVERY_S = 3.0
RESULT_KEYS = ["t", "speed_kmh", "cls", "w_px", "d_raw", "d", "d_min", "level", "sound", "track_id"]


def list_videos() -> list[str]:
    vids: list[Path] = []
    for d in (CLIPS_DIR, UPLOAD_DIR):
        if d.exists():
            vids += sorted(p for p in d.iterdir() if p.suffix.lower() in VIDEO_EXT)
    return [str(p) for p in vids]


class Session:
    """Một video đang mở + luồng YOLO chạy nền đuổi theo vị trí đang xem."""

    def __init__(self, video: str, make_detector: Callable[[], Callable], out_dir: Path = OUT_DIR):
        import cv2
        self.video = video
        self.cache_file = detcache.cache_path(video, str(out_dir))
        cap = cv2.VideoCapture(video)
        if not cap.isOpened():
            raise ValueError(f"Không mở được video: {video}")
        self.fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        self.width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        cap.release()
        self.frames: list = [None] * n
        if self.cache_file.exists():
            old = detcache.load(self.cache_file)
            for i, fr in enumerate(old.get("frames", [])[:n]):
                self.frames[i] = fr
        self.lock = threading.Lock()
        self.calc_lock = threading.Lock()
        self.calc = None          # IncrementalReplay cho tham số hiện tại
        self.params = None        # ResultsReq lần cuối web gửi lên
        self.playhead = 0
        self.version = 0          # tăng mỗi khi có frame mới nhận diện → web biết để tính lại
        self.error: Optional[str] = None
        self._make_detector = make_detector
        self._stop = threading.Event()
        self._dirty = False
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    # ---------- dữ liệu ----------
    def data(self) -> dict:
        with self.lock:
            frames = list(self.frames)
        return {"video": self.video, "fps": self.fps, "width": self.width, "height": self.height, "frames": frames}

    def done(self) -> int:
        with self.lock:
            return sum(fr is not None for fr in self.frames)

    def coverage(self, bins: int = 200) -> list[float]:
        """Tỉ lệ đã nhận diện theo từng đoạn của clip, để vẽ lên thanh tiến độ."""
        with self.lock:
            n = len(self.frames)
            if n == 0:
                return []
            k = min(bins, n)
            out = []
            for b in range(k):
                a, z = b * n // k, (b + 1) * n // k
                out.append(sum(fr is not None for fr in self.frames[a:z]) / max(1, z - a))
            return out

    def _next_frame(self, cur: Optional[int]) -> Optional[int]:
        """Frame cần nhận diện tiếp: frame chưa có đầu tiên từ chỗ đang xem trở đi, hết thì quay về đầu clip."""
        with self.lock:
            n, p = len(self.frames), min(max(self.playhead, 0), max(len(self.frames) - 1, 0))
            if cur is not None and p <= cur < n and self.frames[cur] is None:
                return cur  # đang đọc liền mạch phía trước chỗ xem: cứ đọc tiếp
            for i in range(p, n):
                if self.frames[i] is None:
                    return i
            for i in range(0, p):
                if self.frames[i] is None:
                    return i
        return None

    def _run(self):
        import cv2
        try:
            det = self._make_detector()
        except Exception as e:  # noqa: BLE001 - báo lên web thay vì chết lặng
            self.error = f"Không tải được YOLO: {e}"
            return
        cap = cv2.VideoCapture(self.video)
        pos: Optional[int] = None   # frame mà cap.read() sẽ trả về tiếp theo
        last_save = time.monotonic()
        try:
            while not self._stop.is_set():
                i = self._next_frame(pos)
                if i is None:
                    self._save()
                    self._stop.wait(0.3)
                    pos = None
                    continue
                if i != pos:
                    cap.set(cv2.CAP_PROP_POS_FRAMES, i)
                ok, frame = cap.read()
                if not ok:
                    with self.lock:   # số frame trong header nhiều hơn thực tế: cắt bớt
                        if self.frames[i] is None:
                            self.frames = self.frames[:i]
                            self.version += 1
                    pos = None
                    continue
                rows = [[round(d.x1, 1), round(d.y1, 1), round(d.x2, 1), round(d.y2, 1), d.cls, round(d.conf, 3)]
                        for d in det(frame)]
                with self.lock:
                    self.frames[i] = rows
                    self.version += 1
                    self._dirty = True
                pos = i + 1
                if time.monotonic() - last_save > SAVE_EVERY_S:
                    self._save()
                    last_save = time.monotonic()
        except Exception as e:  # noqa: BLE001
            self.error = f"Lỗi khi nhận diện: {e}"
        finally:
            cap.release()
            self._save()

    def _save(self):
        if not self._dirty:
            return
        detcache.save(self.data(), self.cache_file)
        self._dirty = False

    def close(self):
        self._stop.set()
        self._thread.join(timeout=10)


def default_detector():
    from .detect import Detector
    d = config.load()["detection"]
    return Detector(d["model"], tuple(d["classes"]), d["min_conf"])


class OpenReq(BaseModel):
    path: str


class StateReq(BaseModel):
    playhead: int = 0


class ResultsReq(BaseModel):
    cfg: dict
    speed_t: list[float] = [0.0]
    speed_v: list[float] = [90.0]
    min_conf: float = 0.0


class SaveReq(BaseModel):
    cfg: dict


def create_app(make_detector: Callable[[], Callable] = default_detector, out_dir: Path = OUT_DIR) -> FastAPI:
    state: dict = {"session": None}

    @asynccontextmanager
    async def lifespan(_app):
        yield
        if state["session"] is not None:
            state["session"].close()

    app = FastAPI(title="SafeGap viewer", lifespan=lifespan)
    law = config.load_law()

    def sess() -> Session:
        s = state["session"]
        if s is None:
            raise HTTPException(400, "Chưa mở video")
        return s

    @app.get("/", response_class=HTMLResponse)
    def index():
        return HTML.read_text(encoding="utf-8")

    @app.get("/api/videos")
    def videos():
        return {"videos": list_videos(), "config": config.load()}

    @app.post("/api/upload")
    async def upload(request: Request, name: str):
        safe = Path(name).name
        if Path(safe).suffix.lower() not in VIDEO_EXT:
            raise HTTPException(400, "Không phải file video")
        UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
        dest = UPLOAD_DIR / safe
        with open(dest, "wb") as f:
            async for chunk in request.stream():
                f.write(chunk)
        return {"path": str(dest)}

    @app.post("/api/open")
    def open_video(req: OpenReq):
        path = req.path.strip()
        if not Path(path).is_file():
            raise HTTPException(404, f"Không thấy file: {path}")
        if state["session"] is not None:
            state["session"].close()
            state["session"] = None
        try:
            state["session"] = s = Session(path, make_detector, out_dir)
        except ValueError as e:
            raise HTTPException(400, str(e)) from e
        return {"video": path, "name": Path(path).name, "fps": s.fps, "width": s.width, "height": s.height,
                "n_frames": len(s.frames), "done": s.done()}

    @app.get("/api/video")
    def video_file():
        return FileResponse(sess().video)

    @app.post("/api/state")
    def poll(req: StateReq):
        s = sess()
        s.playhead = req.playhead
        return {"version": s.version, "done": s.done(), "n_frames": len(s.frames), "error": s.error,
                "coverage": s.coverage()}

    def calc(s: Session):
        """Kết quả pipeline cho tham số đang chọn, tính tiếp phần YOLO mới chạy thêm (không tính lại từ đầu)."""
        with s.calc_lock:
            if s.calc is None:
                p: ResultsReq = s.params or ResultsReq(cfg=config.load())
                speed = SpeedTrack(p.speed_t, p.speed_v)
                s.calc = IncrementalReplay(s.fps, s.width, s.height, p.cfg, law, speed.at, p.min_conf)
            with s.lock:
                frames, version = list(s.frames), s.version
            return s.calc.update(frames), version

    def columns(res, start: int = 0, end: Optional[int] = None) -> dict:
        cols: dict = {k: [] for k in RESULT_KEYS}
        for r in res[start:end]:
            for k in RESULT_KEYS:
                cols[k].append(None if r is None else getattr(r, k))
        return cols

    @app.post("/api/params")
    def set_params(req: ResultsReq):
        """Đổi tham số (f, ROI, ngưỡng…): tính lại cả clip trên detection đã có, trả kết quả đầy đủ."""
        s = sess()
        with s.calc_lock:
            s.params, s.calc = req, None
        return full_results()

    @app.get("/api/results")
    def full_results():
        s = sess()
        res, version = calc(s)
        p = s.params or ResultsReq(cfg=config.load())
        return {"version": version, "roi": roi_to_pixels(p.cfg["roi"]["polygon"], s.width, s.height), **columns(res)}

    @app.get("/api/frames")
    def frames_window(start: int, end: int):
        """Detection + kết quả quanh chỗ đang xem (nhẹ, gọi liên tục khi đang phát)."""
        s = sess()
        res, version = calc(s)
        start, end = max(0, start), min(len(res), end)
        with s.lock:
            dets = s.frames[start:end]
        return {"version": version, "start": start, "dets": dets, "res": columns(res, start, end)}

    @app.post("/api/save_config")
    def save_config(req: SaveReq):
        with open(config.CONFIG_DIR / "default.json", "w", encoding="utf-8") as f:
            json.dump(req.cfg, f, ensure_ascii=False, indent=2)
            f.write("\n")
        return {"ok": True}

    return app


def main(argv=None):
    import uvicorn
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8501)
    p.add_argument("--no-browser", action="store_true", help="không tự mở trình duyệt")
    args = p.parse_args(argv)
    url = f"http://127.0.0.1:{args.port}"
    print(f"SafeGap viewer: {url}  (Ctrl+C để dừng)")
    if not args.no_browser:
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    uvicorn.run(create_app(), host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
