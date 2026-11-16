# SafeGap – Hỗ trợ tài xế mới: công việc chi tiết và tiến độ

File này là **nguồn sự thật** cho việc mở rộng app (biển báo, đèn giao thông, mẫu xe). Thread / người làm sau
đọc file này trước, làm tiếp mục `[ ]` đầu tiên của giai đoạn đang làm, và **cập nhật file này trong cùng PR**
(đánh `[x]`, ghi PR, ghi chú điều học được).

Plan đầy đủ (lý do, ngân sách tính toán, rủi ro): Claude Doc "SafeGap – Plan hỗ trợ tài xế mới"
(https://claude.ai/artifact/YQVdAiR1Poier8WiwXXAvd). File này tóm phần cần để làm.

## Đã chốt với chủ app (16/11/2026)

- App **dùng cá nhân**: được pretrain bằng bộ dữ liệu phi thương mại (Mapillary, Stanford Cars, CompCars...).
- Máy chạy: **iPhone 11** (nóng ban ngày, ~10–13 fps). Giữ tổng tải model lớn ≈ mức hiện tại (~15 lượt/giây).
- Thu dữ liệu: mỗi ngày chạy **1 tuyến đi làm cố định**, nhiều loại đường. App tự chụp + ghi log, tối xuất ra,
  chủ app gán nhãn (CVAT / Label Studio) rồi train thêm.
- Train trên **Mac M5** (Ultralytics, `--device mps`); dùng lại luồng dataset/train đã có ở repo `iamcot/11vision`
  (`src/elevenvision/dataset.py`, `reid_train.py`), export Core ML trên chính máy đó (`scripts/export_coreml.sh`).
- Giọng cảnh báo vui: xưng **"bro" / "cưng"** (ngẫu nhiên mỗi câu), đổi được trong Cài đặt.
- Thứ tự: A (nền tảng) → B (biển báo) → C (đèn) → D (mẫu xe) → E (mở rộng).

## Quy ước code

- **Push thẳng lên `main`** (chủ app chốt 16/11/2026: không tạo PR mỗi phiên, chủ app chỉ `git pull` main để test).
  Sau khi push xem CI `core-linux` (test lõi Swift) và `Python prototype`; đỏ thì sửa ngay. Job `app-build` (macOS) hay bị huỷ
  vì chờ máy: không cần chờ, chủ app tự build bằng Xcode trên máy mình (16/11/2026).

- Logic thuần (luật, sự kiện đường, lịch chạy model, chính sách giọng nói) viết trong `ios/SafeGapCore`
  (chỉ Foundation, có test, CI chạy `swift test` trên Linux). Phần dính iOS (AVFoundation, Vision, CoreMotion) ở `ios/SafeGap`.
- Ngưỡng / luật / câu nói để trong `config/*.json`, không hard-code (giống `law_vn.json`).
- Thư mục `ios/SafeGap/` được Xcode đồng bộ với target: thêm file `.swift` là tự vào app, không sửa `project.pbxproj`.
- Sau này port Android (Kotlin): logic mới luôn nằm trong SafeGapCore (chỉ Foundation), test với số cụ thể để port
  1-1 sang Kotlin; tham số / luật / câu nói để trong `config/*.json` dùng chung; model export từ cùng `.pt` (Core ML + TFLite).
- Không có Swift trên máy Linux của Claude: kiểm tra bằng CI của PR (`core-linux` + `app-build` macOS).

## Giai đoạn A – Nền tảng (xong phần code, còn đo trên xe)

- [x] A0. File tiến độ này.
- [x] A1. `Odometer`, `StopDetector`, `TurnDetector`, `JunctionTracker` (`SafeGapCore/RoadEvents.swift`) + test.
      Rẽ: tích phân tốc độ quay quanh trục thẳng đứng (gyro chiếu lên trọng lực) hoặc hướng GPS khi không có gyro.
      Ngã tư: lấy từ `RoadAhead.junctions` (OSM) + quãng đường đã đi; qua ngã tư khi vượt 5 m.
- [x] A2. `InferenceScheduler` (`SafeGapCore/InferenceScheduler.swift`) + test: fps theo tác vụ × mức nhiệt × đứng/chạy.
      Đứng yên thì xe phía trước giảm còn 5 fps (bớt nóng lúc chờ đèn).
- [x] A3. `VoicePolicy` (`SafeGapCore/Voice.swift`) + test: hàng đợi ưu tiên, nghỉ theo loại và theo câu, bỏ câu cũ;
      `VoiceAlerts` (`SafeGap/Audio/VoiceAlerts.swift`) đọc bằng `AVSpeechSynthesizer` giọng vi-VN.
- [x] A4. Đèn giao thông thô từ lớp `traffic light` của YOLO COCO: chọn đèn liên quan + màu theo HSV + bỏ phiếu
      (`SafeGapCore/TrafficLight.swift`) + test; app lấy mẫu màu trong khung đèn từ buffer YCbCr.
      Hiển thị: cụm 3 đèn (đỏ/vàng/xanh) ở giữa mép trên màn hình (`UI/TrafficLightView.swift`), đèn đang sáng phát sáng,
      nhấp nháy khi đang giữ trạng thái vì mất đèn (chủ app yêu cầu: hình đèn, không chỉ chữ).
      Cảnh báo thử: "Đèn đỏ phía trước" (đang chạy nhanh, gần ngã tư/đèn to), "Đèn xanh rồi" (đứng yên > 2 s sau khi xanh).
- [x] A5. Nối vào `FrameProcessor` + HUD: dòng trạng thái đèn / ngã tư kế tiếp / lần rẽ gần nhất; Cài đặt bật/tắt
      giọng nói và đèn giao thông.
- [x] A6. Chế độ thu dữ liệu (`SafeGapCore/Capture.swift` + `SafeGap/Logging/DataCapture.swift`): Cài đặt >
      "Thu dữ liệu". Khi chạy 1 ảnh/4 s, thấy đèn 1 ảnh/2 s (cả lúc chờ đèn), tối đa 1500 ảnh/phiên
      (~3.000 ảnh/ngày cho 2 chuyến × 1,5 giờ; chủ app gán nhãn ~300–500 ảnh/tối, chọn ảnh có biển/đèn/cảnh mới).
      Mỗi phiên `Documents/captures/capture_<giờ>/`: `images/*.jpg` (frame 1920×1080), `labels/*.txt` (YOLO, gán sẵn
      bằng model hiện tại), `classes.txt` (thứ tự `YOLOLabel.classes`, lớp mới thêm vào CUỐI), `meta.jsonl`
      (giờ, GPS, hướng, tốc độ, màu đèn, nhiệt). Nút ZIP + chia sẻ trong Cài đặt.
      Không làm mờ biển số: chủ app chốt ảnh lưu cá nhân, giữ nguyên để sau này có dữ liệu train cả biển số.
- [ ] A7. Đo trên xe: fps / nhiệt 30 phút ban ngày khi bật đèn giao thông; kiểm tra rẽ / ngã tư / đứng yên trên log
      1 chuyến đi làm. Ghi số đo vào mục "Ghi chú đo đạc" dưới đây.
- [ ] A8. Thêm cột vào log CSV: `light`, `junction_m`, `turn`, `stopped_s` (cập nhật `proto/` nếu cần đọc).

## Giai đoạn B – Biển báo lõi (đang làm: luật xong, chờ dữ liệu để train model)

- [x] B1. Luật theo QCVN 41:2024/BGTVT Điều 26 (đã đọc: https://hethongphapluat.com/quy-chuan-ky-thuat-quoc-gia-qcvn-41-2024-bgtvt-ve-bao-hieu-duong-bo/dieu-26)
      → `config/signs_vn.json` (đã thêm vào Resources của Xcode project). Tóm tắt: P.101–P.120 không có phạm vi / biển hết
      cấm (`entry`); P.123 chỉ tại khu vực đặt biển, P.124 tại nơi giao nhau / chỗ mở dải phân cách (`atJunction`);
      P.125–P.127, P.130, P.131 tới nơi đường giao nhau tiếp giáp hoặc biển hết cấm DP.133/134/135 (`untilJunction`);
      P.121, P.128 tới hết cự ly S.501 (`distance`); giao với ngõ, ngách, hẻm **không** làm hết hiệu lực (26.9).
- [ ] B1b. Ngã tư từ OSM đang tính cả đường `residential`/`unclassified` (có thể là hẻm). Thêm lọc: chỉ tính nút có
      nhánh cấp ≥ tertiary, hoặc đường nhánh có tên/rộng; kiểm tra trên log tuyến đi làm.
- [ ] B2. Dataset: Zalo AI 2020 + bộ VN trên Roboflow/Kaggle + Mapillary (pretrain) + ảnh tự thu (A6) + ảnh tổng hợp
      từ hình mẫu QCVN. Lớp dò theo hình dạng (tròn đỏ, tròn xanh, tam giác, chữ nhật) + lớp `traffic_light`.
- [x] B2a. Công cụ gộp ảnh tự thu: `uv run python -m proto.dataset merge|split|train` (`proto/dataset.py`, test trong
      `tests/test_tools.py`). Chỉ lấy phiên có file `REVIEWED` (đã sửa nhãn), gộp lớp theo tên (lớp mới thêm cuối
      `classes.txt`), chia train/val theo cụm 2 phút, train `--device mps`, tắt lật ngang (biển trái/phải đổi nghĩa).
      Export: `./scripts/export_coreml.sh <best.pt> [tên]`. Chưa có: tải/convert dataset công khai (Zalo AI 2020...).
- [x] B2b. Trang gán nhãn `/label` trong web viewer (`uv run python -m proto.viewer` → http://127.0.0.1:8501/label,
      `proto/labeler.py` + `labeler.html`). Kéo thả .zip phiên vào trang (hoặc chép vào `~/safegap-dataset/inbox/`),
      sửa khung máy khoanh, vẽ khung biển theo mã QCVN (lớp = lớp app + mã trong `signs_vn.json` + `sign_other`),
      phím 1–9 / `/` tìm lớp, Enter = duyệt + ảnh sau. Duyệt ghi `<phiên>/review.json`; merge chỉ lấy ảnh đã duyệt.
      Nút "Gộp + Train" chạy merge + train nền, log hiện trên trang.
- [x] B2c. Nhập bộ "Biển báo giao thông Việt Nam (Zalo)" trên Roboflow (CC BY 4.0, chủ app đã fork + tải v1 YOLOv11,
      4803 ảnh toàn cảnh, 7 lớp: Cam con lai, Cam dung va do, Cam nguoc chieu, Cam re, Gioi han toc do, Hieu lenh, Nguy hiem):
      `uv run python -m proto.dataset import-roboflow <thư mục>` → `<dataset>/signs`. Bộ dò biển dùng **nhóm biển**
      (`SIGN_GROUPS`: no_entry, no_stop_park, no_turn, speed_limit, prohibit_other, mandatory, warning, end_restriction,
      sign_other); mã QCVN tự gán gom về nhóm (`sign_group`). Train riêng: `train --task signs` (imgsz 1280), không gộp
      với model xe vì ảnh Roboflow không khoanh xe. Mã biển cụ thể (P.123a hay b, 40 hay 50) để classifier B4.
      → 16/11/2026 23:27: chủ app đang train lần đầu trên M5 (`signs_20261116_2327`, 3205 train / 1598 val, imgsz 1280,
        batch 8, ~5 phút/epoch). Bước tiếp: xem results.png / mAP50, export Core ML, nối vào app: model biển riêng
        chạy theo `InferenceScheduler` (task signs), nhóm → `SignSighting` (no_stop_park → P.130 tạm, no_entry → P.102,
        speed_limit → P.127 chưa có số, no_turn → cần classifier B4 để biết trái/phải/quay đầu).
- [ ] B3. Train dò biển (YOLO11n, vùng cắt 640×360) trên Mac M5, export Core ML, chạy 4 lượt/giây xen kẽ 2 vùng cắt
      qua `InferenceScheduler` (task `signsLights`). Đo nhiệt.
- [ ] B4. Classifier ~12–40 loại biển (64×64), bỏ phiếu ≥ 3 lần; tracker biển; lọc biển trên thân xe / mặt nghiêng.
- [x] B5. `SignEngine` (`SafeGapCore/Signs.swift`) + test `SignTests.swift` (đọc thẳng `config/signs_vn.json`):
      hiệu lực từ lúc đi qua biển (odometer), hết khi qua ngã tư (bỏ qua ngã tư ngay sau lưng biển < 15 m), khi rẽ,
      biển hết cấm, biển cùng loại mới (tốc độ 50 → 40), S.501, hết hạn an toàn 1,5 km (không bản đồ) / 5 km.
      Khung giờ S.508 (`TimeWindow`, qua nửa đêm được), ngày chẵn/lẻ (P.131b/c), loại xe (P.103a/P.106a).
- [x] B6. Cảnh báo: cấm dừng đỗ (đứng ≥ 3 s, trừ kẹt xe: xe trước < 8 m, hoặc đèn đỏ), cấm đỗ (≥ 60 s), cấm rẽ /
      quay đầu (nhắc ≤ 80 m trước ngã tư; "Cấm rẽ trái!" khi đang rẽ và ngã tư < 40 m), quá tốc độ (> giới hạn + 3 km/h
      trong 3 s), biển cấm đi vào nói ngay khi thấy (kèm khung giờ). Còn thiếu: đọc S.508 / S.501 bằng OCR (cần model B3/B4).
- [x] B7. Hàng icon biển trên màn lái dưới số tốc độ (`UI/SignIconsView.swift`, vẽ kiểu biển thật, mờ khi ngoài khung giờ).
      Cài đặt > "Giả lập biển báo": nút "vừa đi qua biển" để thử luật khi chưa có model. Chưa có "hết hiệu lực ở ngã tư X m".
      Model nhận biển chỉ cần gọi `FrameProcessor.addSighting(SignSighting(...))`.
- [ ] B8. Bản đồ biển tự học trên tuyến quen: lưu biển đã xác nhận theo GPS + hướng, lần sau nhắc dù model bỏ sót.

## Giai đoạn C – Đèn giao thông đầy đủ

- [ ] C1. Classifier trạng thái (đỏ/vàng/xanh/mũi tên trái-thẳng-phải/tắt) thay HSV.
- [ ] C2. Đọc đồng hồ đếm ngược (classifier chữ số LED 7 đoạn, kiểm tra giảm 1/giây).
- [ ] C3. Giữ trạng thái + đếm ngược khi đèn ra khỏi khung; thử camera 0,5x khi đứng yên.
- [ ] C4. Cảnh báo đèn vàng lưỡng lự, mũi tên không cho rẽ.

## Giai đoạn D – Mẫu xe + báo giá vui

- [ ] D1. Thu ảnh đuôi xe phía trước (A6), gán nhãn hãng; classifier hãng (~20 hãng).
- [ ] D2. Classifier dòng xe (~50 mẫu phổ biến VN), rơi về hãng khi không chắc.
- [ ] D3. `config/car_prices_vn.json` (khoảng giá lăn bánh, phân khúc) + `config/funny_lines_vi.json` ({xe}, {gia}, {xung_ho}).
- [ ] D4. Chỉ nói khi VÀNG/ĐỎ khoảng cách hoặc bám < 10 m trong phố, xe từ trung cấp trở lên, ≤ 1 câu / 3 phút.

## Giai đoạn E – Mở rộng

- [ ] Biển hướng dẫn làn R.411 (làn thứ mấy từ `LaneTracker` + số làn OSM), biển "Cự ly tối thiểu" → `d_min`, ban đêm.

## Ghi chú đo đạc / học được

- (chưa có số đo trên xe cho giai đoạn A)
- Thử bằng clip (16/11): đèn đỏ bị giữ mãi khi chui hầm, đèn vàng bị kẹt. Nguyên nhân: frame "không rõ màu" không được
  bỏ phiếu nên màu cũ sống mãi; đỏ LED qua camera ngả cam (hue 15–25) bị đọc thành vàng. Sửa: bỏ phiếu cả "không rõ",
  đỏ tới hue 26, vị trí bóng sáng trong khung (đỏ trên/trái, xanh dưới/phải) quyết định khi hue lưỡng lự, mất đèn lúc
  đang chạy ≥ 10 km/h chỉ giữ 2 s (đứng yên vẫn 8 s), qua ngã tư / vừa rẽ thì xoá trạng thái đèn.

## Lịch sử PR

- A0–A6: PR #5 (đã merge). Từ giai đoạn B: commit thẳng lên main.
- B1, B5, B6, B7, B2a, B2b: commit trên main 16/11/2026. App hiển thị tên 'Lái mới' (bundle/target vẫn SafeGap).
