# Model YOLO cho app

File model không commit lên git (nặng, xem `.gitignore`). Tạo trên Mac:

```bash
cd <repo safegap>
uv run --isolated --no-project --python 3.11 \
  --with ultralytics --with "torch==2.7.1" --with "torchvision==0.22.1" \
  --with "coremltools==8.3.0" --with "numpy<2" \
  yolo export model=yolo11n.pt format=coreml nms=True imgsz=384,640
```

Phải ghim phiên bản: coremltools chưa hỗ trợ torch quá mới và numpy 2.x (lỗi `only 0-dimensional arrays can be converted to Python scalars`).
Môi trường `--isolated` này tách khỏi `.venv` của prototype, không ảnh hưởng gì.

Lệnh trên ra `yolo11n.mlpackage`. Kéo (hoặc chép) vào thư mục `ios/SafeGap/Models/` này.
Xcode tự thêm vào app vì thư mục `SafeGap/` được đồng bộ với target. Đổi sang `yolov8n` cũng được:
app lấy model `.mlmodelc` đầu tiên có tên bắt đầu bằng "yolo".
