# SafeGap iOS (Phase 2)

```
ios/
├── SafeGapCore/          # Swift Package: lõi port 1-1 từ proto/ (lane, distance, tracker, alert, pipeline)
│   └── Tests/            # test so khớp output Python (Fixtures/golden.json) + test viết tay
├── SafeGap.xcodeproj     # app iPhone (cần Xcode 16 trở lên)
└── SafeGap/              # code app: Camera, Detection, Sensors, Calibration, UI, Audio, Logging, Models
```

## Chạy test lõi (không cần iPhone)

```bash
cd ios/SafeGapCore
swift test
```

Sửa logic trong `proto/` thì sinh lại dữ liệu mẫu rồi chạy lại test Swift:

```bash
uv run python -m proto.fixtures     # ghi ios/SafeGapCore/Tests/SafeGapCoreTests/Fixtures/golden.json
```

## Cài lên iPhone

Nhanh nhất: `scripts/dev.sh` (export model nếu chưa có, chạy test lõi, mở Xcode), rồi làm bước 2–3 dưới đây.

1. Export model YOLO (một lần), xem `SafeGap/Models/README.md`:
   ```bash
   ./scripts/export_coreml.sh            # hoặc: ./scripts/export_coreml.sh yolov8n
   ```
2. Mở `ios/SafeGap.xcodeproj`. Target SafeGap > Signing & Capabilities: chọn Team (Apple ID miễn phí được).
   Nếu báo trùng bundle id thì đổi `com.iamcot.safegap` thành tên khác.
3. Cắm iPhone, chọn máy, bấm Run. Lần đầu: trên iPhone vào Cài đặt > Cài đặt chung > VPN & Quản lý thiết bị để tin cậy.
   Cho phép Camera và Vị trí khi app hỏi.

App khoá màn hình **ngang, camera (tai thỏ) bên trái**. Màn hình không tự tắt khi app mở.

## Hiệu chỉnh theo máy (làm mỗi khi đổi điện thoại hoặc đổi chỗ gắn giá)

Bấm ◎ trên HUD:
- **ROI**: kéo 4 chấm trắng để hình thang ôm làn của mình (đỉnh trên ở khoảng chân trời).
- **Capo**: kéo chấm cam lên sát trên capo. Box chạm dưới vạch cam hoặc rộng hơn % khung đã chọn bị bỏ.
- **f**: mặc định lấy `fx` từ intrinsics của iOS mỗi frame. Muốn kiểm tra: bật "Kiểm tra f bằng tờ A4",
  dán tờ A4 nằm ngang lên tường, đặt máy cách tường đúng khoảng cách đã chọn, kéo 2 vạch xanh vào 2 mép giấy
  (tinh chỉnh từng px bằng nút +/−). Lệch vài % so với intrinsics là bình thường. Bấm "Dùng f này" nếu muốn dùng f đo tay.
- Bấm **Lưu**. Hiệu chỉnh lưu trên chính điện thoại, theo model máy + lens + độ phân giải; `config/default.json` chỉ là giá trị khởi đầu.

Thứ tự ưu tiên f: đo tay > intrinsics > tính từ HFOV của định dạng camera > `default.json`. HUD hiện nguồn f đang dùng.

## Thử khi đứng yên

Cài đặt (⚙) > "Tốc độ giả lập": đặt ví dụ 90 km/h để xem cảnh báo mà không cần chạy xe. Nhớ tắt trước khi lái.

## Log

Mỗi lần mở app ghi một file `logs/safegap_YYYYMMDD_HHmmss.csv` (app Tệp > Trên iPhone > SafeGap).
11 cột đầu giống CSV của `proto/run_video.py`, thêm `time, f_px, f_source, n_dets, infer_ms, speed_acc_kmh`.

## Chưa làm (Phase 3)

Bù pitch bằng CoreMotion, camera 2x, nhận diện vạch làn, giảm fps khi máy nóng.
