#!/usr/bin/env bash
# Export YOLO sang CoreML cho app iOS và chép vào ios/SafeGap/Models/.
#   ./scripts/export_coreml.sh            # yolo11n
#   ./scripts/export_coreml.sh yolov8n    # model khác
#   ./scripts/export_coreml.sh ~/safegap-dataset/runs/safegap/weights/best.pt [tên]   # model tự train
#                                          (tên mặc định safegap_drive → safegap_drive.mlpackage)
#   ./scripts/export_coreml.sh ~/safegap-dataset/signs/runs/<lần train>/weights/best.pt signs 736,1280   # model dò biển
#                                          (tên phải bắt đầu bằng "signs"; ảnh 16:9 to vì biển rất nhỏ)
# Chạy trong môi trường uv riêng, ghim phiên bản (coremltools chưa hỗ trợ torch quá mới và numpy 2.x),
# không đụng .venv của prototype.
set -euo pipefail

MODEL="${1:-yolo11n}"
IMGSZ="384,640"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ios/SafeGap/Models"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ "$MODEL" == *.pt ]]; then
  SRC="$MODEL"
  MODEL="${2:-safegap_drive}"
  IMGSZ="${3:-384,640}"
  cp "$SRC" "$WORK/$MODEL.pt"
fi
cd "$WORK"
uv run --isolated --no-project --python 3.11 \
  --with "ultralytics" \
  --with "torch==2.7.1" --with "torchvision==0.22.1" \
  --with "coremltools==8.3.0" --with "numpy<2" \
  yolo export model="$MODEL.pt" format=coreml nms=True imgsz=$IMGSZ

mkdir -p "$DEST"
rm -rf "$DEST/$MODEL.mlpackage"
mv "$WORK/$MODEL.mlpackage" "$DEST/"
echo "Đã chép $MODEL.mlpackage vào $DEST. Mở ios/SafeGap.xcodeproj rồi Run."
