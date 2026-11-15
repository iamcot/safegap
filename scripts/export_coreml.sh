#!/usr/bin/env bash
# Export YOLO sang CoreML cho app iOS và chép vào ios/SafeGap/Models/.
#   ./scripts/export_coreml.sh            # yolo11n
#   ./scripts/export_coreml.sh yolov8n    # model khác
# Chạy trong môi trường uv riêng, ghim phiên bản (coremltools chưa hỗ trợ torch quá mới và numpy 2.x),
# không đụng .venv của prototype.
set -euo pipefail

MODEL="${1:-yolo11n}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ios/SafeGap/Models"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
uv run --isolated --no-project --python 3.11 \
  --with "ultralytics" \
  --with "torch==2.7.1" --with "torchvision==0.22.1" \
  --with "coremltools==8.3.0" --with "numpy<2" \
  yolo export model="$MODEL.pt" format=coreml nms=True imgsz=384,640

mkdir -p "$DEST"
rm -rf "$DEST/$MODEL.mlpackage"
mv "$WORK/$MODEL.mlpackage" "$DEST/"
echo "Đã chép $MODEL.mlpackage vào $DEST. Mở ios/SafeGap.xcodeproj rồi Run."
