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
