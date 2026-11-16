# Model YOLO cho app

File model không commit lên git (nặng, xem `.gitignore`). Tạo trên Mac:

```bash
./scripts/export_coreml.sh            # hoặc: ./scripts/export_coreml.sh yolov8n
```

Phải ghim phiên bản: coremltools chưa hỗ trợ torch quá mới và numpy 2.x (lỗi `only 0-dimensional arrays can be converted to Python scalars`).
Script chạy trong môi trường `--isolated` tách khỏi `.venv` của prototype, không ảnh hưởng gì.

Script tự chép `yolo11n.mlpackage` vào thư mục `ios/SafeGap/Models/` này.
Xcode tự thêm vào app vì thư mục `SafeGap/` được đồng bộ với target. Đổi sang `yolov8n` cũng được:
app lấy model `.mlmodelc` đầu tiên có tên bắt đầu bằng "yolo".

## Model dò biển (tuỳ chọn, docs/DRIVER_ASSIST.md B3)

Sau khi train (`uv run python -m proto.dataset train --task signs ...`):

```bash
./scripts/export_coreml.sh ~/safegap-dataset/signs/runs/<lần train>/weights/best.pt signs 736,1280
```

Script chép `signs.mlpackage` vào đây. App tự nạp model có tên bắt đầu bằng "signs", chạy 3–4 lần/giây ở hàng đợi riêng
(Cài đặt > Hỗ trợ tài xế > Dò biển báo bằng model). Không có file này thì app chạy như cũ.
Lớp của model = nhóm biển (`SignGroup` trong SafeGapCore = `SIGN_GROUPS` trong proto/dataset.py, cùng thứ tự).
