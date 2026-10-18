#!/bin/bash
# 앱 아이콘 생성 — 둥근 사각형 위에 "한".
# 디자인 자산이 없어 코드로 그린다. 한 번 돌려 Resources/AppIcon.icns 를 커밋하면
# 빌드할 때마다 다시 그릴 필요가 없다.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/draw.swift" <<'SWIFT'
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// 배경 — 둥근 사각형(진한 남색)
let inset = size * 0.06
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.20, alpha: 1).setFill()
path.fill()

// 글자 — "한"
let text = "한" as NSString
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: size * 0.52, weight: .semibold),
    .foregroundColor: NSColor.white,
]
let bounds = text.size(withAttributes: attrs)
text.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2),
          withAttributes: attrs)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("아이콘 렌더 실패\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

echo ">> 1024px 렌더"
swiftc -O -o "$WORK/draw" "$WORK/draw.swift"
"$WORK/draw" "$WORK/icon.png"

echo ">> iconset 조립"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512; do
    sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "완료: Resources/AppIcon.icns"
