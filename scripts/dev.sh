#!/usr/bin/env bash
# Bắt đầu làm việc bằng MỘT lệnh.
#
#   scripts/dev.sh           # app iOS: export model nếu chưa có, test lõi Swift, mở Xcode
#   scripts/dev.sh viewer    # viewer Python để xem / chỉnh tham số trên video (http://127.0.0.1:8501)
#   scripts/dev.sh test      # chạy hết test: pytest + swift test
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-ios}"
cd "$ROOT"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "✗ Thiếu '$1'. $2"; exit 1; }
}

py_test() {
  need uv "Cài: brew install uv"
  echo "► pytest"
  uv run pytest -q
}

swift_test() {
  need swift "Cài Xcode (kèm Command Line Tools)."
  echo "► swift test (ios/SafeGapCore)"
  ( cd ios/SafeGapCore && swift test )
}

case "$MODE" in
  ios)
    need xcodebuild "Cài Xcode 16 trở lên."
    if ! ls ios/SafeGap/Models/*.mlpackage >/dev/null 2>&1; then
      echo "► Chưa có model YOLO trong app, export lần đầu (vài phút)…"
      "$ROOT/scripts/export_coreml.sh"
    else
      echo "✓ Model: $(cd ios/SafeGap/Models && ls -d *.mlpackage | tr '\n' ' ')"
    fi
    swift_test
    echo "► Mở Xcode. Chọn iPhone của bạn rồi bấm Run (⌘R)."
    echo "  Lần đầu: target SafeGap > Signing & Capabilities > chọn Team."
    open ios/SafeGap.xcodeproj
    ;;
  viewer)
    need uv "Cài: brew install uv"
    echo "► Viewer: http://127.0.0.1:8501  (Ctrl+C để dừng)"
    exec uv run python -m proto.viewer
    ;;
  test)
    py_test
    if command -v swift >/dev/null 2>&1; then swift_test; else echo "(bỏ qua swift test: máy không có Swift)"; fi
    ;;
  *)
    sed -n '2,7p' "$0"
    exit 1
    ;;
esac
