# SafeGap

Cảnh báo khoảng cách an toàn trên cao tốc bằng camera iPhone. Kế hoạch chi tiết: [SafeGap.md](SafeGap.md).

## Prototype Python (Phase 1)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r proto/requirements.txt

pytest tests                                   # unit test, không cần video
python -m proto.calib a4 --w-px <px> --dist 3  # tính f từ ảnh tờ A4
python -m proto.run_video data/clips/<clip>.mp4 --speed data/clips/<clip>_speed.csv --out out/
python -m proto.eval data/groundtruth.csv --logs out/
```

Config: `config/law_vn.json` (bảng luật tốc độ → d_min), `config/default.json` (f, bề rộng xe, ROI, ngưỡng).
