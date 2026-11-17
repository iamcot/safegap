#!/bin/sh
# Build bản Release rồi cài lên iPhone đang cắm cáp / cùng wifi, KHÔNG mở app, không gắn debugger.
# Mở app bằng tay trên máy, app chạy bình thường như bản cài thật (Release nhanh hơn Debug).
#   scripts/install_device.sh            # tự chọn iPhone đầu tiên đang kết nối
#   scripts/install_device.sh <udid>     # chọn máy (xem: xcrun devicectl list devices)
set -eu
cd "$(dirname "$0")/.."
DD=build/device
xcodebuild -project ios/SafeGap.xcodeproj -scheme SafeGap -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" -allowProvisioningUpdates -quiet build
APP="$DD/Build/Products/Release-iphoneos/SafeGap.app"
DEV="${1:-}"
if [ -z "$DEV" ]; then
  TMP=$(mktemp)
  xcrun devicectl list devices --json-output "$TMP" >/dev/null
  DEV=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))['result']['devices']
ok=[x for x in d if x.get('hardwareProperties',{}).get('platform')=='iOS' and x.get('connectionProperties',{}).get('tunnelState')!='unavailable']
print(ok[0]['identifier'] if ok else '')" "$TMP")
  rm -f "$TMP"
fi
[ -n "$DEV" ] || { echo "Không thấy iPhone nào. Cắm cáp / mở khoá máy rồi chạy lại." >&2; exit 1; }
xcrun devicectl device install app --device "$DEV" "$APP"
echo "Đã cài. Mở app Lái mới trên iPhone."
