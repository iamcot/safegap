# SafeGap

Cảnh báo khoảng cách an toàn trên cao tốc bằng camera iPhone. Kế hoạch chi tiết: [SafeGap.md](SafeGap.md).

## Prototype Python (Phase 1)

Dùng [uv](https://docs.astral.sh/uv/): **không cần cài Python**, uv tự tải Python 3.11 và cài thư viện
đúng phiên bản trong `uv.lock` vào `.venv`.

```bash
brew install uv          # macOS (hoặc: curl -LsSf https://astral.sh/uv/install.sh | sh)
uv sync                  # lần đầu: tải Python 3.11 + thư viện

uv run pytest                                          # unit test, không cần video
uv run python -m proto.calib a4 --w-px <px> --dist 3   # tính f từ ảnh tờ A4
uv run python -m proto.run_video data/clips/<clip>.mp4 --speed data/clips/<clip>_speed.csv --out out/
uv run python -m proto.eval data/groundtruth.csv --logs out/
```

Thêm thư viện: `uv add <tên>` (tự cập nhật `pyproject.toml` và `uv.lock`).

### Xem và debug video trên Mac (web local)

```bash
uv run python -m proto.viewer      # tự mở http://127.0.0.1:8501
```

Chọn video ở thanh bên (để trong `data/clips/`, nhập đường dẫn, hoặc kéo thả file). Video phát thẳng trong trình duyệt,
box / ROI / D / màu cảnh báo vẽ chồng lên. **YOLO chạy nền bắt đầu từ chỗ đang xem**: kéo tới đâu nhận diện tới đó,
không phải chờ chạy hết clip. Máy chậm (không GPU) thì bật "Chờ YOLO khi phát" để video tự dừng chờ YOLO bắt kịp.
Trên Mac chip Apple, YOLO tự dùng GPU (MPS). Kết quả lưu ở `out/<tên>_dets.json`, mở lại clip là có sẵn.

Chỉnh f (config / nhập tay / từ HFOV), bề rộng xe, ROI, ngưỡng ở thanh bên: kết quả đổi ngay, không chạy lại YOLO.
Không có file tốc độ thì dùng thanh trượt tốc độ cố định. Thanh xanh dưới video là phần đã nhận diện, biểu đồ D theo
thời gian bấm vào để tua. Phím: Space phát/dừng, ←/→ 1 frame, Shift+←/→ 1 giây. **Lưu config** ghi tham số vào
`config/default.json`, **Tải CSV log** xuất kết quả từng frame.

Config: `config/law_vn.json` (bảng luật tốc độ → d_min), `config/default.json` (f, bề rộng xe, ROI, ngưỡng).

## App iPhone (Phase 2)

Code Swift trong `ios/`: lõi `ios/SafeGapCore` (port từ `proto/`, test so khớp output Python) và app `ios/SafeGap.xcodeproj`.
Cách build, cài lên iPhone và hiệu chỉnh camera theo máy: [ios/README.md](ios/README.md).
