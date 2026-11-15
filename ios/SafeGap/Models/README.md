# Model YOLO cho app

File model không commit lên git (nặng, xem `.gitignore`). Tạo trên Mac:

```bash
cd <repo safegap>
uv run --with coremltools yolo export model=yolo11n.pt format=coreml nms=True imgsz=384,640
```

Lệnh trên ra `yolo11n.mlpackage`. Kéo (hoặc chép) vào thư mục `ios/SafeGap/Models/` này.
Xcode tự thêm vào app vì thư mục `SafeGap/` được đồng bộ với target. Đổi sang `yolov8n` cũng được:
app lấy model `.mlmodelc` đầu tiên có tên bắt đầu bằng "yolo".
