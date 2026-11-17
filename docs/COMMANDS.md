# Câu lệnh cần biết

Chạy ở thư mục gốc repo trên Mac. Lần đầu: `brew install uv`, cài Xcode.

## Hằng ngày

```bash
git pull                                   # lấy code mới (Claude push thẳng lên main)
scripts/dev.sh                             # export model xe nếu chưa có, test lõi Swift, mở Xcode
scripts/dev.sh test                        # chạy hết test: pytest + swift test
scripts/dev.sh viewer                      # web xem clip + trang gán nhãn (http://127.0.0.1:8501)
scripts/install_device.sh                  # build Release + cài lên iPhone, không mở app, không debugger
```

Cài app mà không bị Xcode giữ: `scripts/install_device.sh` (cắm cáp hoặc cùng wifi, máy mở khoá). Xong mở app bằng tay,
app chạy độc lập và nhanh hơn bản Debug. Nếu đã bấm Run trong Xcode: menu **Debug > Detach from SafeGap**, rồi Stop
cũng không tắt app.

## Gán nhãn ảnh tự thu (mỗi tối)

1. Trên iPhone: Cài đặt > Phiên thu dữ liệu > chia sẻ .zip sang Mac (AirDrop).
2. Mở trang gán nhãn:

```bash
uv run python -m proto.viewer              # rồi mở http://127.0.0.1:8501/label (hoặc bấm "Gán nhãn →")
```

3. Kéo thả file .zip vào trang, hoặc chép vào `~/safegap-dataset/inbox/`.
4. Phím tắt: kéo chuột để vẽ khung · `1`–`9` chọn lớp · `/` tìm lớp (ví dụ "P.130", "cấm đỗ") · `Del` xoá khung ·
   `Enter` duyệt rồi sang ảnh sau · `←` `→` chuyển ảnh · `H` ẩn/hiện khung · `Ctrl/⌘Z` hoàn tác.
   `M` cho model khoanh lại. Chỉ ảnh đã duyệt mới được đưa vào train.
5. Ảnh chưa duyệt được model mới nhất đã train (biển + xe) khoanh sẵn bằng **khung nét đứt**: sai thì xoá / sửa, đúng
   thì cứ Enter. Lần đầu mở trang chờ vài giây để nạp model. Tắt bằng ô "Gợi ý khung".
   Ảnh model trên xe thấy biển có ghi "· biển" trong danh sách.

## Train trên Mac M5

```bash
# chạy qua đêm: caffeinate giữ máy không ngủ (để mở nắp hoặc cắm màn hình ngoài)

# bộ dò biển (nhóm biển): lần đầu nhập bộ Roboflow (Zalo, YOLOv11)
uv run python -m proto.dataset import-roboflow ~/datasets/vn-signs
caffeinate -i uv run python -m proto.dataset train --task signs --batch 8 --name signs

# vạch / mũi tên mặt đường (lớp mark_*, chỉ ảnh có khung vạch; cần ≥ 20 ảnh)
caffeinate -i uv run python -m proto.dataset train --task marks --name marks
./scripts/export_coreml.sh ~/safegap-dataset/marks/runs/<tên>/weights/best.pt marks 544,960

# model xe + đèn từ ảnh tự gán (gộp các phiên đã duyệt trong inbox trước)
uv run python -m proto.dataset merge ~/safegap-dataset/inbox
caffeinate -i uv run python -m proto.dataset train --epochs 80 --name drive

# train tiếp từ model lần trước
caffeinate -i uv run python -m proto.dataset train --task signs --batch 8 --name signs \
  --model ~/safegap-dataset/signs/runs/<lần trước>/weights/best.pt
```

Hoặc trên trang `/label`, cột trái "Train trên Mac": chọn Model rồi bấm **Gộp + Train**. Trang hiện thanh tiến độ, giờ xong
dự kiến và điểm mAP50 theo epoch (log gốc ở "Log chi tiết"). Train chạy tách riêng và tự giữ máy thức: refresh trang hay
tắt / mở lại viewer đều không ảnh hưởng.

Kết quả nằm ở `~/safegap-dataset/runs/<tên>/` (xe), `~/safegap-dataset/signs/runs/<tên>/` (biển) hoặc `~/safegap-dataset/marks/runs/<tên>/` (vạch mặt đường).
Xem `results.png` (mAP50 càng cao càng tốt) và `val_batch0_pred.jpg` (ảnh model đoán thử).

## Đưa model vào app

```bash
./scripts/export_coreml.sh                                                          # model xe COCO gốc (yolo11n)
./scripts/export_coreml.sh ~/safegap-dataset/signs/runs/<tên>/weights/best.pt signs 736,1280   # model biển
```

Script chép `.mlpackage` vào `ios/SafeGap/Models/`, mở Xcode rồi Run.
Kiểm tra trong app: Cài đặt > Hỗ trợ tài xế > dòng "Model biển: signs".

## Thử trong app khi không lái xe

- Chiếu clip đường phố lên màn hình, cho camera iPhone quay vào.
- Cài đặt > "Giả lập biển báo": bấm biển để thử luật (cấm dừng đỗ, cấm rẽ, tốc độ...) mà không cần model.
- Cài đặt > tốc độ giả lập: thử cảnh báo khi đang đứng yên.

## Công cụ Python khác

```bash
uv run pytest -q                                              # test Python
uv run python -m proto.calib a4 --w-px <px> --dist 3          # tính tiêu cự f từ ảnh tờ A4
uv run python -m proto.run_video data/clips/<clip>.mp4 --speed data/clips/<clip>_speed.csv --out out/
uv run python -m proto.eval data/groundtruth.csv --logs out/
uv run python -m proto.triplog <log.csv>                      # xem lại log CSV chuyến đi
(cd ios/SafeGapCore && swift test)                            # test lõi Swift
```

Khi thêm lệnh mới, cập nhật file này.
