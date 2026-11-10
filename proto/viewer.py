"""SafeGap debug viewer – trang web chạy local để xem thuật toán trên video đã quay.

    streamlit run proto/viewer.py

1. Chọn video (trong data/clips/ hoặc kéo thả), bấm "Chạy YOLO" (chạy 1 lần, có cache).
2. Tua frame, xem box, D, d_min, màu cảnh báo; biểu đồ D theo thời gian.
3. Chỉnh f, bề rộng xe, ROI, ngưỡng ở thanh bên: kết quả cập nhật ngay, không cần chạy lại YOLO.
4. Bấm "Lưu config" để ghi tham số vào config/default.json.
"""
import copy
import csv
import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import cv2  # noqa: E402
import streamlit as st  # noqa: E402

from proto import config, detcache  # noqa: E402
from proto.calib import f_from_hfov  # noqa: E402
from proto.overlay import draw  # noqa: E402
from proto.pipeline import Pipeline  # noqa: E402
from proto.replay import replay  # noqa: E402
from proto.speed import SpeedTrack  # noqa: E402

CLIPS_DIR = ROOT / "data" / "clips"
OUT_DIR = ROOT / "out"
UPLOAD_DIR = OUT_DIR / "uploads"
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".avi", ".mkv"}

st.set_page_config(page_title="SafeGap viewer", layout="wide")


@st.cache_resource
def get_detector(model, classes, min_conf):
    from proto.detect import Detector
    return Detector(model, tuple(classes), min_conf)


@st.cache_data(show_spinner=False)
def load_cache(path: str, mtime: float):
    return detcache.load(Path(path))


@st.cache_data(show_spinner=False)
def run_replay(data_key: str, _data: dict, cfg_json: str, law_json: str, speed_key: str, _speed):
    return replay(_data, json.loads(cfg_json), json.loads(law_json), _speed)


def read_frame(video: str, i: int):
    cap = cv2.VideoCapture(video)
    cap.set(cv2.CAP_PROP_POS_FRAMES, i)
    ok, frame = cap.read()
    cap.release()
    return frame if ok else None


def list_videos():
    vids = []
    for d in (CLIPS_DIR, UPLOAD_DIR):
        if d.exists():
            vids += sorted(p for p in d.iterdir() if p.suffix.lower() in VIDEO_EXT)
    return vids


# ---------------- Sidebar: video ----------------
base_cfg = config.load()
law = config.load_law()

st.sidebar.title("SafeGap viewer")
up = st.sidebar.file_uploader("Kéo thả video", type=[e[1:] for e in VIDEO_EXT])
if up is not None:
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    dest = UPLOAD_DIR / up.name
    if not dest.exists() or dest.stat().st_size != up.size:
        dest.write_bytes(up.getbuffer())

videos = list_videos()
manual = st.sidebar.text_input("…hoặc đường dẫn video", "")
choices = [str(p) for p in videos]
video = manual.strip() or (st.sidebar.selectbox("Video", choices, format_func=lambda p: Path(p).name)
                            if choices else None)
if not video:
    st.info("Chưa có video. Kéo thả vào thanh bên, hoặc copy vào `data/clips/`.")
    st.stop()
if not Path(video).exists():
    st.error(f"Không thấy file: {video}")
    st.stop()

cache_file = detcache.cache_path(video, str(OUT_DIR))
c1, c2 = st.sidebar.columns(2)
run_yolo = c1.button("Chạy YOLO" if not cache_file.exists() else "Chạy lại YOLO", type="primary")
if run_yolo:
    det_cfg = base_cfg["detection"]
    det = get_detector(det_cfg["model"], det_cfg["classes"], det_cfg["min_conf"])
    bar = st.sidebar.progress(0.0, "Đang chạy YOLO…")
    data = detcache.detect_video(video, det, lambda i, n: bar.progress(min(1.0, i / max(n, 1)), f"YOLO {i}/{n}"))
    detcache.save(data, cache_file)
    bar.empty()
if not cache_file.exists():
    st.info("Bấm **Chạy YOLO** để nhận diện xe trên cả clip (chạy 1 lần, kết quả được lưu lại).")
    st.stop()
data = load_cache(str(cache_file), cache_file.stat().st_mtime)
W, H, fps, n_frames = data["width"], data["height"], data["fps"], len(data["frames"])
c2.caption(f"{W}×{H}, {fps:.0f} fps, {n_frames} frame")

# ---------------- Sidebar: tham số ----------------
cfg = copy.deepcopy(base_cfg)
st.sidebar.subheader("Tốc độ xe mình")
speed_csv = st.sidebar.file_uploader("File tốc độ CSV (t_s,speed_kmh)", type=["csv"])
if speed_csv is not None:
    speed = SpeedTrack.from_csv(io.TextIOWrapper(io.BytesIO(speed_csv.getvalue()), encoding="utf-8"))
    speed_key = f"csv:{speed_csv.name}:{speed_csv.size}"
else:
    v_const = st.sidebar.slider("Tốc độ cố định (km/h)", 0, 130, 90, 5)
    speed = SpeedTrack([0.0], [float(v_const)])
    speed_key = f"const:{v_const}"

st.sidebar.subheader("Tiêu cự f")
cam = cfg["camera"]
f_mode = st.sidebar.radio("Cách lấy f", ["Theo config", "Nhập f", "Từ HFOV"], horizontal=True)
f_frame = cam["f_px"] * W / cam["f_px_image_width"]
if f_mode == "Nhập f":
    f_frame = st.sidebar.number_input("f (px, ở độ rộng video này)", 100.0, 20000.0, round(f_frame, 1), 10.0)
elif f_mode == "Từ HFOV":
    hfov = st.sidebar.slider("HFOV (độ)", 30.0, 110.0, 69.0, 0.5,
                             help="iPhone camera 1x quay video khoảng 63–70°, tuỳ máy và chống rung")
    f_frame = f_from_hfov(W, hfov)
cam["f_px"], cam["f_px_image_width"] = round(f_frame, 1), W
st.sidebar.caption(f"f = {f_frame:.0f} px @ {W} px")

st.sidebar.subheader("Bề rộng xe (m)")
for k in list(cfg["vehicle_width_m"]):
    cfg["vehicle_width_m"][k] = st.sidebar.slider(k, 1.4, 3.0, float(cfg["vehicle_width_m"][k]), 0.05)

st.sidebar.subheader("ROI (xe cùng làn)")
poly = cfg["roi"]["polygon"]  # [TL, TR, BR, BL]
top_y = st.sidebar.slider("Cạnh trên (y)", 0.2, 0.9, float(poly[0][1]), 0.01)
top_l, top_r = st.sidebar.slider("Cạnh trên: trái / phải (x)", 0.0, 1.0, (float(poly[0][0]), float(poly[1][0])), 0.01)
bot_l, bot_r = st.sidebar.slider("Cạnh dưới: trái / phải (x)", 0.0, 1.0, (float(poly[3][0]), float(poly[2][0])), 0.01)
cfg["roi"]["polygon"] = [[top_l, top_y], [top_r, top_y], [bot_r, 1.0], [bot_l, 1.0]]

with st.sidebar.expander("Cảnh báo & lọc"):
    a = cfg["alert"]
    a["red_ratio"] = st.slider("Ngưỡng ĐỎ (× d_min)", 0.5, 1.0, float(a["red_ratio"]), 0.05)
    a["yellow_ratio"] = st.slider("Ngưỡng VÀNG (× d_min)", 1.0, 1.5, float(a["yellow_ratio"]), 0.05)
    a["hold_s"] = st.slider("Giữ ổn định (s)", 0.0, 3.0, float(a["hold_s"]), 0.1)
    a["min_speed_kmh"] = st.slider("Không cảnh báo dưới (km/h)", 0, 80, int(a["min_speed_kmh"]), 5)
    manual = st.number_input("d_min chỉnh tay (m, 0 = theo luật)", 0, 200, int(a["manual_d_min_m"] or 0), 5)
    a["manual_d_min_m"] = manual or None
    t = cfg["tracker"]
    t["meas_rel_sigma"] = st.slider("Nhiễu đo Kalman (tương đối)", 0.01, 0.3, float(t["meas_rel_sigma"]), 0.01,
                                    help="Lớn hơn → D mượt hơn nhưng phản ứng chậm hơn")
    t["accel_sigma"] = st.slider("Gia tốc Kalman (m/s²)", 0.5, 10.0, float(t["accel_sigma"]), 0.5)
    min_conf = st.slider("Độ tin cậy tối thiểu", 0.0, 0.9, float(cfg["detection"]["min_conf"]), 0.05,
                         help="Chỉ lọc được trên kết quả đã cache (không thấp hơn lúc chạy YOLO)")
    cfg["detection"]["min_conf"] = min_conf

if st.sidebar.button("Lưu config vào config/default.json"):
    with open(config.CONFIG_DIR / "default.json", "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    st.sidebar.success("Đã lưu.")

# ---------------- Chạy pipeline ----------------
filtered = dict(data, frames=[[d for d in fr if d[5] >= min_conf] for fr in data["frames"]])
results = run_replay(f"{cache_file}:{cache_file.stat().st_mtime}:{min_conf}", filtered,
                     json.dumps(cfg, sort_keys=True), json.dumps(law, sort_keys=True), speed_key, speed.at)

# ---------------- Main ----------------
st.title(Path(video).name)

reds = [r.frame for r in results if r.sound]
if "frame" not in st.session_state or st.session_state.get("video") != video:
    st.session_state.frame, st.session_state.video = 0, video
b1, b2, b3, b4 = st.columns([1, 1, 1, 3])
if b1.button("◀ 1 giây"):
    st.session_state.frame = max(0, st.session_state.frame - int(fps))
if b2.button("1 giây ▶"):
    st.session_state.frame = min(n_frames - 1, st.session_state.frame + int(fps))
if b3.button("Lần ĐỎ tiếp ▶", disabled=not reds):
    nxt = [f for f in reds if f > st.session_state.frame]
    st.session_state.frame = (nxt or reds)[0]
b4.caption(f"{len(reds)} lần vào ĐỎ trong clip")
i = st.slider("Frame", 0, n_frames - 1, key="frame")

r = results[i]
frame = read_frame(video, i)
if frame is not None:
    dets = detcache.frame_dets(filtered, i)
    pipe_roi = Pipeline(cfg, law, W, H).roi
    draw(cv2, frame, pipe_roi, dets, r)
    st.image(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB), use_container_width=True)

m = st.columns(6)
m[0].metric("Thời điểm", f"{r.t:.1f} s")
m[1].metric("D (lọc)", f"{r.d:.1f} m" if r.d is not None else "--")
m[2].metric("D (thô)", f"{r.d_raw:.1f} m" if r.d_raw is not None else "--")
m[3].metric("d_min", f"{r.d_min:.0f} m" if r.d_min is not None else "--")
m[4].metric("Tốc độ", f"{r.speed_kmh:.0f} km/h" if r.speed_kmh is not None else "--")
m[5].metric("Trạng thái", r.level)
if r.w_px is not None:
    st.caption(f"Xe: {r.cls}, rộng {r.w_px:.1f} px, track #{r.track_id}")

st.subheader("Khoảng cách theo thời gian")
chart = {
    "t (s)": [x.t for x in results],
    "D thô": [x.d_raw for x in results],
    "D lọc": [x.d for x in results],
    "d_min": [x.d_min for x in results],
}
st.line_chart(chart, x="t (s)", y=["D thô", "D lọc", "d_min"])

buf = io.StringIO()
w = csv.DictWriter(buf, fieldnames=list(results[0].row()))
w.writeheader()
for x in results:
    w.writerow(x.row())
st.download_button("Tải CSV log", buf.getvalue(), file_name=f"{Path(video).stem}.csv", mime="text/csv")
