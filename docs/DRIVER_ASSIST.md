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
  Lệnh mới cho chủ app (train, export, công cụ) thì ghi thêm vào `docs/COMMANDS.md`.
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
      sign_other, no_park); mã QCVN tự gán gom về nhóm (`sign_group`). Train riêng: `train --task signs` (imgsz 1280), không gộp
      với model xe vì ảnh Roboflow không khoanh xe. Mã biển cụ thể (P.123a hay b, 40 hay 50) để classifier B4.
      → Kết quả lần 1 (`signs_20261116_2327`, 80 epoch, xong 17/11 6h): mAP50 0,614, mAP50-95 0,412, P 0,886, R 0,545
        (no_stop_park 0,667 · no_entry 0,644 · no_turn 0,604 · prohibit_other 0,609 · mandatory 0,595 · warning 0,596 ·
        speed_limit 0,582). Đoán ra thì hay đúng, nhưng sót gần nửa biển (chắc là biển nhỏ/xa); tracker cần 3 lần thấy khi
        tới gần nên thực tế khá hơn con số R. Cải thiện: thêm ảnh tự thu tuyến đi làm, thử imgsz lớn hơn / quét vùng cắt.
      → 16/11/2026 23:27: chủ app đang train lần đầu trên M5 (`signs_20261116_2327`, 3205 train / 1598 val, imgsz 1280,
        batch 8, ~5 phút/epoch). Bước tiếp: xem results.png / mAP50, export Core ML, nối vào app: model biển riêng
        chạy theo `InferenceScheduler` (task signs), nhóm → `SignSighting` (no_stop_park → P.130 tạm, no_entry → P.102,
        speed_limit → P.127 chưa có số, no_turn → cần classifier B4 để biết trái/phải/quay đầu).
- [x] B3a. App đọc model dò biển: `YOLODetector(prefix: "signs")` nạp `Models/signs*.mlpackage` (export
      `./scripts/export_coreml.sh <best.pt> signs 736,1280`), chạy ở hàng đợi riêng theo lịch `signsLights` (4/3/2/0 fps),
      `SignDetectionTracker` (SafeGapCore/SignDetection.swift, test SignDetectionTests): ≥ 3 lần trong 1,5 s, conf ≥ 0,35,
      bỏ biển nằm trong khung xe / thấp dưới 80% ảnh, mỗi nhóm báo lại sau ≥ 8 s. Nhóm → SignEngine: no_entry → P.102,
      no_stop_park → P.130, speed_limit → P.127 (chưa có số); nhóm khác chỉ hiện (khung trên camera + chip "đang thấy"
      dưới số tốc độ). Cài đặt: "Dò biển báo bằng model".
- [x] B3b. Vị trí cắm biển (chủ app góp ý 17/11 sau khi thử clip): biển có hiệu lực cho phần đường **bên trái** nó
      (theo hướng nhìn tài xế). `SignDetectionTracker.place`: từ chiều cao khung (biển 0,7 m) + f ra khoảng cách và
      lệch ngang; < −1,5 m = bên trái làn mình (dải phân cách / giữa đường 2 chiều → chiều ngược lại), > số làn × 3,5 + 3,5 m
      = đường ngang / nhánh, rộng/cao < 0,6 = biển quay xiên. `SignEngine.feed`: biển áp dụng có hiệu lực **từ chỗ cắm**
      (`sightedAhead`, rẽ trước khi tới thì bỏ, biển sau ngã tư không bị ngã tư đó xoá); cấm đi ngược chiều ở giữa đường
      chỉ nói khi rẽ trái / quay đầu gần đó, ở miệng đường nhánh bên phải chỉ nói khi rẽ phải (`sightedIfTurn`, ±30 m).
      Biển không áp dụng vẽ xám trên hình camera, không lên chip. Biển tốc độ nhận kém (mAP50 0,58): cần thêm dữ liệu + B4.
- [x] B3c. Biển + GPS + OSM (chủ app đề xuất 17/11): `SafeGapCore/SignMap.swift`. Biển camera xác nhận dành cho làn
      mình (`SignEngine.isOwnRoadSign`) → toạ độ (GPS + hướng + khoảng cách / lệch ngang, `Geo.offset`) → `SignMemory`
      (gộp cùng mã trong 25 m cùng hướng ±45°, trung bình vị trí). `SignRecall`: biển nhớ phía trước ≤ 80 m cùng chiều →
      `sightedAhead` (nhắc trước khi camera thấy, vẫn nhắc nếu camera sót); đi qua mà camera không thấy (model đang chạy)
      → `missed`; sót ≥ 3 và nhiều hơn số lần thấy → xoá. Lưu `Documents/sign_map.json` (30 s / lần), Cài đặt có số biển
      đã nhớ + nút Xoá. Lệch ngang trừ độ cong đường từ OSM (`roadBend`). Tốc độ: `DriveContext.mapSpeedLimitKmh` =
      maxspeed OSM, dùng khi biển P.127 chưa có số hoặc không có biển tốc độ nào.
      Chưa làm: so toạ độ biển với các way OSM để biết biển thuộc đường ngang (GPS lệch 5–10 m, cần thử trên log thật).
- [x] B2d. Thu + gán nhãn nhanh hơn (17/11, chủ app thu sáng + chiều, train qua đêm):
      - Trang `/label` tự khoanh sẵn ảnh chưa duyệt bằng model mới nhất đã train trên Mac (`Suggester`: `best.pt` mới
        nhất trong `<ds>/signs/runs/*` và `<ds>/runs/*`; model xe COCO gốc không dùng vì trùng nhãn máy). Khung nét đứt
        kèm % tin cậy, bỏ khung trùng khung đã có (IoU > 0,4); không tự lưu, duyệt (Enter) mới lưu. Nhóm biển có mã chính
        → mã (no_entry P.102, no_stop_park P.130, speed_limit P.127), nhóm khác giữ tên nhóm làm lớp (`warning`,
        `mandatory`, `no_turn`...; `sign_group` hiểu). Phím `M` khoanh lại, ô "Gợi ý khung" bật/tắt.
      - App: model biển chạy ngưỡng 0,2 (tracker vẫn lọc 0,35); thu dữ liệu chụp mỗi 1,5 s khi model thấy biển (kể cả
        chưa chắc) và xe đang chạy (`CapturePolicy.signIntervalS`); meta.jsonl có `signs`, trang nhãn ghi "· biển".
- [x] B3d. Tách cấm dừng đỗ (P.130, hai vạch chéo X) với cấm đỗ (P.131a, một vạch, vẫn được dừng) (chủ app 17/11):
      - Model: thêm nhóm `no_park` vào **cuối** `SIGN_GROUPS` (chỉ số lớp cũ giữ nguyên, model cũ vẫn chạy). Nhãn tự gán
        P.130 → no_stop_park, P.131a/b/c → no_park. Ảnh Roboflow "Cam dung va do" lẫn cả hai nên vẫn là no_stop_park;
        model chỉ học no_park từ ảnh tự gán, cần gán đủ biển P.131a (vài chục khung trở lên) rồi train lại.
      - Trong lúc chờ (và cho cả biển model vẫn gọi no_stop_park): đếm vạch đỏ chéo trong biển
        (`NoStopParkClassifier`, SignDetection.swift): lưới 16×16 trong khung, bỏ viền đỏ (bán kính > 0,36) và tâm
        (< 0,1), hai dải chéo |u−v| < 0,09 và |u+v−1| < 0,09; cả hai dải đỏ ≥ 30% → P.130, một dải ≥ 30% còn dải kia
        ≤ 15% → P.131a, còn lại không chắc → giữ P.130. Khung cao < 16 px thì không đọc. Tracker bỏ phiếu mã theo track
        (`ConfirmedSign.code`, `lawCode`), luật dùng `lawCode` (P.131a chỉ cấm đỗ ≥ 60 s, không nhắc khi dừng).
        Khung trên camera / chip ghi "Cấm đỗ".
      - Trang gán nhãn: gợi ý no_stop_park cũng đếm vạch như app (`labeler.slash_code`) để đề xuất P.130 hay P.131a;
        no_park → P.131a. P.131b/c (ngày lẻ/chẵn) bạn tự đổi khi gán.
- [x] B3e. Biển phân làn + vạch mặt đường trên trang gán nhãn (chủ app 17/11):
      - Nhóm biển mới `lane_sign` (cuối `SIGN_GROUPS`): R.411 hướng đi từng làn, R.412 làn riêng theo loại xe, R.415 gộp
        làn. Biển chữ nhật xanh treo trên làn, khác biển hiệu lệnh tròn nên tách; app chỉ hiện "Phân làn", chưa áp luật
        (cần đọc mũi tên từng làn, để sau). Bộ Roboflow gộp chúng vào "Hieu lenh" nên model học nhóm này từ ảnh tự gán.
      - `config/sign_catalog_vn.json`: tên các biển hay gặp chưa có luật (R.411/412/415, R.301–303, R.122, P.104,
        P.125, P.128, DP.135, W.207/208/224/225/227/245) để có trong danh sách lớp trang `/label`.
      - Vạch / mũi tên sơn mặt đường (`MARKS` trong proto/dataset.py): mark_straight, mark_left, mark_right,
        mark_straight_left, mark_straight_right, mark_uturn, mark_stop_line, mark_crosswalk, mark_other. Model **riêng**
        (`train --task marks`, imgsz 960, `<ds>/marks`), chỉ lấy ảnh có ít nhất một khung vạch (ảnh cũ chưa khoanh
        mũi tên sẽ dạy sai). Không dùng hộp cho vạch làn (dài, chéo cả khung): vạch làn vẫn do LaneDetector.
        Chưa làm: nạp model marks vào app (mũi tên trước mặt → làn đang đi là làn rẽ hay thẳng, nhắc khi đi sai làn).
- [x] B3f. Trang nhãn nhanh hơn (chủ app 17/11): phím 1–9, 0 = car, truck, motorcycle, traffic light, P.130, P.131a,
      R.411, R.412, P.127, bus. Biển tốc độ: lớp theo mốc `P.127_<số>` (5, 30, 40, 50, 60, 70, 80, 90, 100, 120), thanh
      "Tốc độ" hiện khi lớp / khung đang chọn là biển tốc độ, bấm mốc để đổi. Khi train vẫn gom về nhóm speed_limit;
      mốc giữ lại cho classifier số (B4). Kéo bên trong khung chưa chọn = vẽ khung mới (biển trong khung xe to),
      Shift+kéo luôn vẽ mới.
- [x] B3g. Biển phụ (S.5xx) dưới biển cấm: khoanh **riêng** biển chính và biển phụ (hai khung). Nhóm mới `aux_plate`
      (cuối `SIGN_GROUPS`), danh mục S.501 cự ly, S.502, S.503 hướng, S.505a loại xe, S.508 giờ, S.509 chữ. App chỉ hiện
      "Biển phụ"; sau này: biển phụ nằm ngay dưới biển chính → đọc giờ / cự ly (OCR) để áp `window` / `distance`.
- [x] Sửa sau chạy thử sáng 17/11 (ảnh chủ app gửi: kẹt xe, máy nóng 5 fps):
      - Làn vẽ sai mãi bên phải: (1) bỏ vệt sáng nằm trong khung xe frame trước (`LaneDetector.detect(exclude:)`,
        đèn phanh / biển số / kính xe trước giống vạch); (2) xe đứng yên thì không dò, `RoadLaneFilter.stationary()`
        giữ rồi duỗi về làn thẳng giữa, vẽ mờ, chạy lại thì dò từ đầu không theo cổng; (3) chỉ bám một bên > 60 frame
        → `needsReacquire`, bỏ cổng để dò lại; (4) đổi làn: tâm làn lệch quá nửa làn thì đổi gốc sang làn mới
        (cả mô hình lẫn số đo), không kéo ngang qua giữa.
      - Dừng trong kẹt xe bị nhắc cấm dừng đỗ: chỉ tính khi xe có thể đang sát lề phải. `stopExcused` khi có xe ngay
        bên phải (lệch 1,5–5 m, < 10 m) hoặc GPS + số làn OSM (`RoadMatch.rightEdgeGapM`, chốt lúc còn chạy) cho thấy
        cách mép phải > 1,5 làn sau khi trừ sai số GPS; thấy một lần là miễn cả lần dừng. Xe sát phía trước KHÔNG
        miễn (chủ app: đỗ sau xe đang đỗ cũng là đỗ).
      - Biển cấm ngược chiều bên trái vẫn báo: biển ở xa > 30 m chưa chốt (xa thì biển nào cũng gần tâm ảnh), chốt khi
        tới gần hoặc khi biển ra khỏi khung (theo vị trí cuối); ngưỡng trái −1,5 → −1 m; đường một chiều (OSM) thì
        biển bên trái cũng áp dụng (`leftSideApplies`). Biển đã nhớ sai trước đây: Cài đặt > Xoá bản đồ biển.
      - Đèn đổi màu chậm: 2 lần liên tiếp cùng màu rõ thì đổi ngay (`fastSwitch`); giữ đèn đang theo, chỉ đổi sang
        đèn khác khi to / rõ hơn 1,6 lần (`stickiness`). Nhận diện đèn kém là do lớp traffic light của COCO yolo11n:
        cần gán nhãn đèn trong ảnh tự thu rồi train model xe + đèn (B2).
      - Đọc log 9h09–9h59 (22 nghìn frame): máy nóng "serious" 72% thời gian (~7,5 fps). Ở 1x, cặp vạch thô cắt nhau ở
        y ≈ 0,78 ảnh trong khi chân trời (IMU) ở ≈ 0,53, vạch trái kéo lên lệch phải (điểm tụ x ≈ 0,65), vạch phải lệch
        trái (≈ 0,32): không phải vạch kẻ mà là mép capo / phản chiếu (vạch capo hiệu chỉnh để mặc định 0,97, thấp hơn
        capo thật ~0,83). Ở 2x (capo ra ngoài khung) cặp vạch cắt nhau ở 0,60, khớp chân trời 0,58. Sửa:
        `HorizonCheck` (vạch kéo lên phải tụ gần giữa ảnh trên chân trời, ±0,04 + 0,12·f/W; cặp vạch cắt nhau cách chân
        trời > 0,08 thì bỏ cả hai), log `hz L/R/P`. Chủ app cần chỉnh vạch capo (◎) ở 1x. Đèn: 43% frame thấy đèn
        nhưng màu "không rõ" → bộ phân màu HSV kém ban ngày, cần ảnh thu để chỉnh.
      - Khoảng cách tối thiểu dưới 60 km/h: log cho thấy 11% thời gian chạy phố bị ĐỎ (30 km/h, cách 12–24 m < 35 m).
        Luật chỉ cho số từ 60 km/h; dưới đó dùng quy tắc N giây `below_first_headway_s` (law_vn.json, chủ app chọn 1,5 s cho phố đông,
        sàn 5 m, trần 35 m), Python + Swift cùng công thức.
      - Log: CSV thêm cột `lane_debug` (vạch thô c0/c1, có cổng không, số vệt bị che, lý do bỏ, mô hình
        offset/heading/width, T = đang bám) và `light_debug` (số đèn, màu thô, màu chốt, cao khung);
        meta.jsonl của ảnh thu dữ liệu có `lane`, `lightDebug`.
- [x] A9. Tên đường đang chạy (OSM `name:vi` / `name`, kèm `ref` như QL1A) hiện dưới xe mình trên màn lái
      (`RoadWay.name`, `RoadMatch.name`). Ô OSM tải từ bản cũ (không tên) vẫn dùng, tự tải lại dần ở cuối hàng.
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

- [ ] Tốc độ GPS (để làm sau, 17/11): GPS thấp hơn đồng hồ xe 2–5 km/h. Phần lớn do đồng hồ chỉ dư theo luật (~5–8%),
  nên cảnh báo vẫn tính theo GPS (gần tốc độ thật, máy bắn tốc độ đo tốc độ thật). Việc cần làm: (1) ô "Bù đồng hồ (%)"
  trong Cài đặt, chỉ đổi số hiển thị; (2) chỗ bị che (hẻm, nhà cao, hầm) GPS trễ/tụt: trộn gia tốc kế (CoreMotion) với
  GPS, bỏ qua mẫu có `speedAccuracy` kém (`Sensors/SpeedProvider.swift`).
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
