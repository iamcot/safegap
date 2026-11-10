# SafeGap – Cảnh báo khoảng cách an toàn trên cao tốc bằng camera iPhone

## 1. Mục tiêu

App đặt trên giá gắn kính lái, dùng camera iPhone để:
1. Nhận diện xe **cùng làn** phía trước.
2. Ước lượng khoảng cách D (mét) bằng camera đơn (monocular).
3. Lấy tốc độ xe mình từ GPS, tra bảng luật ra khoảng cách tối thiểu `d_min`.
4. Cảnh báo XANH / VÀNG / ĐỎ (màn hình + âm thanh).

Yêu cầu độ chính xác: **ước lượng**, sai số ±15% ở 30–100m là chấp nhận được. Mục tiêu là trả lời "đủ khoảng cách theo luật hay chưa", không cần số chính xác tuyệt đối.

Ngoài phạm vi MVP: Android, ban đêm/mưa lớn, đọc biển báo "Cự ly tối thiểu", ghi bằng chứng pháp lý.

## 2. Bảng luật (Thông tư 38/2024/TT-BGTVT, đường khô ráo, không có biển riêng)

| Tốc độ xe mình | d_min |
|---|---|
| ≤ 60 km/h | 35 m |
| > 60 – 80 km/h | 55 m |
| > 80 – 100 km/h | 70 m |
| > 100 – 120 km/h | 100 m |

- Bảng này **phải nằm trong file config** (`config/law_vn.json`), không hard-code. Chính phủ đang yêu cầu rà soát Thông tư 38 nên số có thể thay đổi.
- Nơi có biển "Cự ly tối thiểu giữa hai xe" thì giá trị trên biển được ưu tiên (MVP: cho phép người dùng chỉnh tay trước chuyến đi, không cần đọc biển).

## 3. Thuật toán

### 3.1 Phát hiện xe
- Dùng YOLO pretrained (COCO): class `car`, `truck`, `bus` (bỏ `motorcycle` trên cao tốc).
- Model: `yolo11n` (hoặc `yolov8n`), export sang CoreML bằng Ultralytics.
- Không train ở MVP. Chỉ fine-tune nếu thử thực tế thấy bắt xe kém.

### 3.2 Chọn xe cùng làn (ego lane)
- MVP: vùng ROI hình thang ở giữa khung hình (cấu hình được trong config).
- Chọn bounding box có tâm đáy nằm trong ROI và **gần nhất** (đáy box thấp nhất trên ảnh).
- Nâng cấp sau: nhận diện vạch kẻ làn.

### 3.3 Tính khoảng cách – cách chính: bề rộng thân xe
```
D = f_px * W_real / w_px
```
- `f_px`: tiêu cự tính bằng pixel, cùng hệ độ phân giải với `w_px`.
- `W_real` theo loại xe: car ≈ 1.80 m, truck/bus ≈ 2.50 m (để trong config).
- `w_px`: bề rộng bounding box.

### 3.4 Cách phụ: mặt đường (dùng để đối chiếu, có thể tắt)
```
D = f_px * h_cam / (y_bottom - y_horizon)
```
- `h_cam`: chiều cao camera so với mặt đường (đo 1 lần).
- `y_horizon`: dòng chân trời, bù bằng pitch từ CoreMotion.
- Kết hợp 2 cách: trung bình có trọng số, ưu tiên cách 3.3 khi xa.

### 3.5 Lọc nhiễu
- Kalman filter 1D (trạng thái: D, dD/dt) cho mỗi xe được track.
- Track xe qua các frame bằng IoU đơn giản (hoặc ByteTrack ở bản Python).

### 3.6 Quyết định cảnh báo (có hysteresis)
```
v = tốc độ GPS (km/h)
d_min = law_table(v)
if D < 0.9 * d_min: RED
elif D < 1.1 * d_min: YELLOW
else: GREEN
```
- Chỉ đổi trạng thái khi trạng thái mới giữ ổn định ≥ 1 giây (chống nhấp nháy).
- Không cảnh báo khi v < 40 km/h (kẹt xe) hoặc không có xe cùng làn.
- Âm thanh chỉ phát khi vào RED, có cooldown 5 giây.

## 4. Calibrate tiêu cự f_px

Ưu tiên theo thứ tự:
1. **Intrinsic matrix của iOS:** bật `isCameraIntrinsicMatrixDeliveryEnabled` trên `AVCaptureConnection`, đọc `fx` từ metadata mỗi frame (`kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`). Cách này không cần đo tay.
2. **Kiểm chứng bằng tờ A4:** dán tờ A4 nằm ngang lên tường, đứng cách 3 m, đo được `w` pixel, tính `f = w * 3 / 0.297`. So với giá trị ở bước 1.
3. **Dự phòng:** tính từ HFOV, `f = (width/2) / tan(HFOV/2)`.

Lưu ý: đổi ống kính (1x/2x), độ phân giải hay chế độ chống rung thì f thay đổi. Khóa cố định các thông số này trong app.

## 5. Tech stack

| Phần | Công nghệ |
|---|---|
| Prototype offline | Python 3.11, OpenCV, Ultralytics, NumPy, filterpy |
| App iPhone | Swift, SwiftUI, AVFoundation, Vision + CoreML, CoreLocation, CoreMotion |
| Model | YOLO11n → `.mlpackage` (Ultralytics export, `nms=True`) |

Yêu cầu: Mac + Xcode. Apple ID miễn phí cài được lên iPhone của mình (app hết hạn sau 7 ngày, cài lại). Gói Developer trả phí mới dùng TestFlight.

## 6. Cấu trúc repo

```
safegap/
├── PLAN.md
├── config/
│   ├── law_vn.json          # bảng tốc độ → d_min
│   └── default.json         # W_real, ROI, ngưỡng, hysteresis
├── proto/                   # Python, chạy offline trên video
│   ├── calib.py             # tính f từ ảnh A4 / HFOV
│   ├── detect.py            # YOLO wrapper
│   ├── lane.py              # chọn xe cùng làn
│   ├── distance.py          # công thức 3.3, 3.4
│   ├── tracker.py           # Kalman + IoU tracking
│   ├── alert.py             # bảng luật + hysteresis
│   ├── run_video.py         # input video (+ file tốc độ) → video có overlay
│   └── eval.py              # so D ước lượng với ground truth
├── data/
│   ├── clips/               # video quay thử (không commit)
│   └── groundtruth.csv      # clip, frame, khoảng cách thật
└── ios/SafeGap/             # Xcode project
    ├── Camera/              # AVFoundation, intrinsics
    ├── Detection/           # Vision + CoreML
    ├── Estimation/          # port từ proto/ (distance, tracker, alert)
    ├── Sensors/             # GPS speed, CoreMotion pitch
    ├── UI/                  # màn hình HUD
    └── Logging/             # ghi CSV để debug sau chuyến đi
```

## 7. Các giai đoạn

### Phase 0 – Thu dữ liệu
- [ ] Gắn iPhone lên giá cố định, quay **ngang**, camera 1x, 1080p hoặc 4K, 30fps, khóa AE/AF. Tránh vùng chấm đen trên kính lái.
- [ ] Ghi chiều cao camera so với mặt đường (`h_cam`).
- [ ] Ground truth: đỗ sau một xe con, quay mỗi mốc 5 giây ở 10 / 20 / 30 / 50 m (đo bằng thước dây).
- [ ] Quay vài clip cao tốc ban ngày; ghi tốc độ (app GPS logger hoặc nhập tay).
- [ ] Chụp ảnh tờ A4 cách 3 m để calibrate.

**Done khi:** có ≥ 4 mốc ground truth và ≥ 30 phút clip cao tốc.

### Phase 1 – Prototype Python (offline)
- [ ] `calib.py`: tính f từ ảnh A4.
- [ ] `detect.py` + `lane.py`: bắt xe cùng làn trên clip.
- [ ] `distance.py`: tính D theo bề rộng xe.
- [ ] `tracker.py`: Kalman filter, D mượt không nhảy.
- [ ] `alert.py`: đọc `law_vn.json`, hysteresis.
- [ ] `run_video.py`: xuất video có overlay (box, D, d_min, màu cảnh báo).
- [ ] `eval.py`: báo cáo sai số % theo từng mốc ground truth.

**Done khi:** sai số ≤ 15% ở 10–50 m trên dữ liệu ground truth, và overlay trên clip cao tốc nhìn hợp lý.

### Phase 2 – App iPhone MVP
- [ ] Camera pipeline AVFoundation: khóa lens 1x, độ phân giải, tắt chống rung (hoặc ghi lại chế độ đang dùng), lấy intrinsics.
- [ ] Export YOLO sang CoreML, chạy qua Vision, mục tiêu ≥ 15 fps.
- [ ] Port `lane`, `distance`, `tracker`, `alert` sang Swift. Viết unit test với cùng input/output như bản Python.
- [ ] GPS speed (CoreLocation, `kCLLocationAccuracyBestForNavigation`).
- [ ] HUD: số D lớn, d_min, tốc độ, nền xanh/vàng/đỏ. Không cần chạm khi đang lái.
- [ ] Âm thanh cảnh báo khi RED.
- [ ] Logging CSV mỗi frame: thời gian, v, D, d_min, trạng thái, loại xe, w_px.

**Done khi:** chạy ổn định 30 phút trên cao tốc, không quá nóng, cảnh báo khớp cảm nhận thực tế.

### Phase 3 – Cải thiện (tùy chọn)
- [ ] Bù pitch bằng CoreMotion, bật cách tính mặt đường (3.4) để kết hợp.
- [ ] Hỗ trợ camera 2x cho tầm xa.
- [ ] Nhận diện vạch làn thay ROI cố định.
- [ ] Theo dõi `ProcessInfo.thermalState`, tự giảm fps khi máy nóng.
- [ ] Cho chỉnh d_min thủ công (biển cự ly, trời mưa).
- [ ] Sau này: Android (Kotlin + TFLite), dùng lại config và logic.

## 8. Rủi ro và lưu ý

- **Tầm xa:** ở 100 m xe con chỉ còn khoảng 25 px (1080p), lệch 1–2 px là sai 5–8 m. Có thể dùng 4K hoặc camera 2x.
- **Xe khác kích thước chuẩn:** xe mini, xe tải lớn làm lệch D. Dùng `W_real` theo class, chấp nhận sai số.
- **Đường cong, xe đổi làn:** ROI cố định dễ chọn nhầm xe làn bên.
- **Nhiệt độ:** iPhone trên táp-lô dưới nắng dễ bị throttle hoặc tự tắt.
- **Lóa kính:** táp-lô phản chiếu lên kính lái. Dùng khăn tối màu trên táp-lô.
- **An toàn:** app chỉ để tham khảo, không thay thế sự chú ý của tài xế. Không thao tác điện thoại khi đang lái. Kết quả không có giá trị làm bằng chứng pháp lý.
- **Luật thay đổi:** luôn cập nhật `law_vn.json` theo văn bản mới nhất.

## 9. Thông số tham khảo ban đầu

- f ước lượng từ ảnh thử (iPhone 1x, khoảng 2100 px chiều rộng): ≈ 1530 px. Phải calibrate lại cho đúng độ phân giải thật.
- Kiểm tra nhanh trên ảnh thử: xe Mazda6 cách khoảng 10 m, đo bằng biển số và bằng bề rộng thân xe đều ra ~10–10.5 m.
