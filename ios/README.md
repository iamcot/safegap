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

App chạy màn hình **ngang, cầm chiều nào cũng được** (ảnh tự xoay 180° theo hướng máy). Màn hình không tự tắt khi app mở.

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

Phân tích trên Mac (AirDrop file từ app Tệp sang): `uv run python -m proto.triplog safegap_….csv` in tóm tắt chuyến đi và lưu biểu đồ PNG (D, d_min, tốc độ, nền màu theo mức cảnh báo) cạnh file.


Mỗi lần mở app ghi một file `logs/safegap_YYYYMMDD_HHmmss.csv` (app Tệp > Trên iPhone > SafeGap).
11 cột đầu giống CSV của `proto/run_video.py`, thêm `time, f_px, f_source, n_dets, infer_ms, speed_acc_kmh`.

## Phase 3 (trong Cài đặt ⚙)

- **Chạy mát** (mặc định bật): YOLO 15 fps trên Neural Engine. Máy nóng (`thermalState`) thì tự giảm tiếp 12 → 8 → 5 fps
  (tắt chạy mát: 30 → 20 → 12 → 6). HUD báo khi đang giảm.
- **Ẩn hình camera** (mặc định bật): full màn hình là con đường vẽ lại theo mét (sáng/tối theo giao diện máy): vạch làn và các xe (khối 3D) chiếu từ ảnh xuống mặt
  đường (cần f, chiều cao camera và chân trời), làn mình tô xanh dương nhạt, dải từ đầu xe mình tới xe phía trước xanh lá khi an toàn, vàng/đỏ khi gần; xe là ảnh vẽ sẵn (Assets car_own, car_rear, truck_rear), vạch đứt là khoảng cách
  tối thiểu. Viền màn hình sáng vàng/đỏ khi cần chú ý.
  Xe ngược chiều (lại gần nhanh hơn tốc độ xe mình ≥ 15 km/h và ở bên trái làn mình) vẽ bằng ảnh nhìn từ đầu,
  vạch phân cách hai chiều thành nét liền vàng, và không bao giờ được chọn làm xe phía trước. Tắt đi thì về giao diện cũ (camera + bảng HUD).
  Ngoài app: gắn máy ở khe gió điều hoà, tháo ốp, tránh sạc nhanh khi đang chạy.
- **ROI bám vạch làn** (mặc định bật): tìm vạch kẻ đường hai bên làn mình, ROI uốn theo làn khi vào cua. Vạch xanh trên HUD
  là vạch nhận diện được. Không thấy vạch (đường không kẻ, trời tối) thì dùng hình thang đã hiệu chỉnh.
- **Kết hợp đo theo mặt đường** (mặc định bật): chân trời tính từ góc nghiêng máy (CoreMotion), đo thêm theo vị trí đáy xe.
  Cần nhập đúng chiều cao camera trong màn hiệu chỉnh. Ở màn hiệu chỉnh có vạch vàng nét đứt là chân trời: đỗ xe trên đường
  bằng, nếu vạch lệch với điểm tụ của làn thì chỉnh "Bù lệch".
- **Ống kính 2x**: nút 1x/2x trên màn hình chính. Zoom 2x trên camera chính, xe ở xa to gấp đôi nên đo xa chính xác hơn. Hiệu chỉnh (ROI, f tay, vạch capo) lưu riêng theo ống kính, đổi qua lại không phải chỉnh lại; lần đầu dùng 2x app tự suy ra từ hiệu chỉnh 1x.
- **Cảnh báo từ … km/h**: mặc định 40 km/h (dưới mức này coi là kẹt xe). Hạ xuống để thử trong phố.

CSV có thêm cột `thermal`, `lane` (LR / L / R / rỗng), `pitch_deg`, `y_horizon`.
