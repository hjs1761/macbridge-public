#!/bin/bash
# swiftc 빌드 → MacBridge.app 번들 조립 → adhoc 서명 → DMG.
#
#   ./scripts/package_app.sh            번들만
#   ./scripts/package_app.sh --dmg      번들 + DMG
#
# ⚠ 공증(Developer ID)은 Phase 4-C 다. 지금은 adhoc 서명이라 남에게 주면
#   Gatekeeper 경고가 뜬다(우클릭→열기로 넘길 수 있다).
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/build-config.sh

APP_NAME="MacBridge"
BUNDLE_ID="com.hjs.macbridge"
VERSION="${VERSION:-1.0}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo ">> 빌드 v$VERSION — universal(${UNIVERSAL_ARCHS[*]}), 최소 macOS $MIN_MACOS"
mkdir -p "$DIST"
SLICES=()
for arch in "${UNIVERSAL_ARCHS[@]}"; do
    echo "   · $arch"
    swiftc -O -target "$arch-apple-macos$MIN_MACOS" \
        -o "$DIST/macbridge-$arch" main.swift src/*.swift
    SLICES+=("$DIST/macbridge-$arch")
done
lipo -create -output "$DIST/macbridge" "${SLICES[@]}"
rm -f "${SLICES[@]}"

echo ">> 번들 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIST/macbridge" "$APP/Contents/MacOS/macbridge"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
else
    echo "⚠ Resources/AppIcon.icns 없음 — 기본 아이콘으로 진행 (scripts/make_icon.sh 를 먼저 도세요)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>macbridge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo ">> adhoc 서명"
codesign --force --deep --sign - "$APP"
codesign -v "$APP"

# ---------- 검증 ----------
# 이 두 가지는 눈으로 안 보이는 채로 틀린다. plist 는 13.0 이라 적혀 있는데
# 바이너리는 minos 26.0 이라 macOS 13 사용자가 그냥 못 여는 상태로 배포된 적이 있다.
echo ">> 검증"
BIN="$APP/Contents/MacOS/macbridge"
GOT="$(lipo -archs "$BIN")"
# trap 은 한 번만 건다 — 아래 DMG 단계에서 다시 걸면 이게 덮여 TMP 가 남는다
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" ${STAGE:+"$STAGE"}' EXIT
for arch in "${UNIVERSAL_ARCHS[@]}"; do
    case " $GOT " in
        *" $arch "*) ;;
        *) echo "❌ $arch 슬라이스 없음 — 있는 것: $GOT"; exit 1 ;;
    esac
    # 슬라이스별로 따로 본다. 합쳐 놓으면 한쪽만 타깃이 틀려도 겉으론 멀쩡해 보인다
    lipo -thin "$arch" "$BIN" -output "$TMP/$arch"
    MINOS="$(vtool -show-build "$TMP/$arch" | awk '/minos/{print $2}')"
    [ "$MINOS" = "$MIN_MACOS" ] || {
        echo "❌ $arch 의 minos=$MINOS (기대: $MIN_MACOS) — swiftc -target 확인"; exit 1; }
done
PLIST_MIN="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")"
[ "$PLIST_MIN" = "$MIN_MACOS" ] || {
    echo "❌ Info.plist=$PLIST_MIN 인데 바이너리=$MIN_MACOS — 둘이 어긋났다"; exit 1; }
echo "   $GOT · 최소 macOS $MIN_MACOS · 서명 유효"

if [ "${1:-}" = "--dmg" ]; then
    echo ">> DMG"
    STAGE="$(mktemp -d)"   # 정리는 위에서 건 trap 이 함께 한다
    ditto "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DIST/$APP_NAME-$VERSION.dmg"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
        "$DIST/$APP_NAME-$VERSION.dmg" >/dev/null
    echo "완료: $DIST/$APP_NAME-$VERSION.dmg"
fi

echo "완료: $APP"
