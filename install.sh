#!/bin/bash
# macbridge 설치 — 빌드 → ~/bin 배치 → config.json 생성/갱신 → LaunchAgent 등록
#
#   ./install.sh                          기존 config.json 그대로 재설치(빌드만 갱신)
#   ./install.sh <PEER> [<PEER> ...]      피어를 지정하며 both(양방향) 모드로 설치
#   ./install.sh --mode serve             수신 전용
#   ./install.sh --mode watch <PEER> ...  송신 전용
#   ./install.sh uninstall
#
# 설정은 ~/.config/macbridge/config.json 이 유일한 원본이다. 세부 조정은 그 파일을 직접 고칠 것.
# 재실행해도 직접 넣은 키(hotkeys/actions 등)는 보존된다.
#
# 토큰은 config.json 안에 있고 **모든 기기가 같은 값이어야 한다.**
# 한쪽에서 먼저 설치해 생성된 값을 다른 쪽 config.json 에 복사할 것.
# (v0 ime-sync 의 ~/.config/ime-sync/token 이 있으면 자동으로 물려받는다)

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/bin"
BIN="$BIN_DIR/macbridge"
CFG_DIR="$HOME/.config/macbridge"
CFG="$CFG_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/com.hjs.macbridge.plist"
LABEL="com.hjs.macbridge"
BAR_LABEL="com.hjs.macbridge.menubar"
BAR_PLIST="$HOME/Library/LaunchAgents/com.hjs.macbridge.menubar.plist"
LOG="$HOME/Library/Logs/macbridge.log"

# v0(ime-sync) 잔재 — 남겨 두면 같은 UDP 포트를 두 데몬이 물어 패킷이 어디로 갈지 알 수 없다
OLD_LABEL="com.hjs.imesync"
OLD_PLIST="$HOME/Library/LaunchAgents/com.hjs.imesync.plist"
OLD_BIN="$HOME/bin/ime-sync"
OLD_TOKEN="$HOME/.config/ime-sync/token"

PORT_DEFAULT=8765
# Jump Desktop 뷰어. 이 앱이 최전면일 때만 동기화한다("지금 원격 거는 쪽"만 송신하게 되는 효과).
# 항상 동기화하려면 config.json 의 ime_sync.only_app 을 null 로.
ONLY_APP_DEFAULT="com.p5sys.jump.mac.viewer"

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

# ---------- 인자 ----------
MODE=""
PEERS=()
while [ $# -gt 0 ]; do
    case "$1" in
        uninstall) MODE="uninstall"; shift ;;
        --mode)    MODE="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        -*)        echo "!! 알 수 없는 옵션: $1"; usage ;;
        *)         PEERS+=("$1"); shift ;;
    esac
done

# ---------- uninstall ----------
if [ "$MODE" = "uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$BAR_LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$BAR_PLIST" "$BIN"
    echo "제거 완료. 설정(${CFG})은 남겨 뒀습니다 — 지우려면 직접 삭제하세요."
    exit 0
fi

[ -z "$MODE" ] && MODE="both"
case "$MODE" in
    serve|watch|both) ;;
    *) echo "!! --mode 는 serve/watch/both 중 하나여야 합니다 (받은 값: $MODE)"; usage ;;
esac
# ⚠ 피어 없이도 설치된다 — 갓 설치한 기기는 상대를 모르는 게 정상이고,
#   설정 창의 「기존 기기에 연결…」(페어링)로 채우면 된다.
if [ "$MODE" != "serve" ] && [ ${#PEERS[@]} -eq 0 ] && [ ! -f "$CFG" ]; then
    echo "ℹ 연결할 기기를 지정하지 않았습니다."
    echo "  설치 후 메뉴바 → 설정… → 기기 → 「기존 기기에 연결…」 에서 연결 코드로 붙이세요."
    echo "  (IP 를 아신다면: ./install.sh 100.64.0.1)"
fi

# ---------- config.json 생성/갱신 ----------
# 기존 파일이 있으면 병합한다 — 직접 넣은 키(hotkeys/actions 등)를 지우지 않기 위해서.
mkdir -p "$CFG_DIR"
TOKEN_SEED="$(openssl rand -hex 16)"
LEGACY_TOKEN=""
[ -f "$OLD_TOKEN" ] && LEGACY_TOKEN="$(tr -d '[:space:]' < "$OLD_TOKEN")"

CFG_PATH="$CFG" NEW_MODE="$MODE" NEW_PEERS="${PEERS[*]:-}" \
PORT="$PORT_DEFAULT" ONLY_APP="$ONLY_APP_DEFAULT" \
SEED="$TOKEN_SEED" LEGACY="$LEGACY_TOKEN" \
DEVICE_ID="$(uuidgen)" DEVICE_NAME="$(scutil --get ComputerName 2>/dev/null || hostname)" \
python3 - <<'PY'
import json, os, sys

path   = os.environ["CFG_PATH"]
cfg    = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except Exception as e:
        sys.exit(f"!! 기존 config.json 을 읽지 못했습니다: {e}\n   고치거나 옮긴 뒤 다시 실행하세요: {path}")

cfg["mode"] = os.environ["NEW_MODE"]
cfg.setdefault("port", int(os.environ["PORT"]))

peers = [p for p in os.environ["NEW_PEERS"].split() if p]
if peers:
    cfg["peers"] = peers
cfg.setdefault("peers", [])

# 토큰 우선순위: 기존 config > v0 token 파일(마이그레이션) > 새로 생성
if not cfg.get("token"):
    legacy = os.environ.get("LEGACY", "").strip()
    cfg["token"] = legacy or os.environ["SEED"]
    print("토큰: " + ("기존 ime-sync 토큰을 물려받았습니다" if legacy else "새로 생성했습니다"))

cfg.setdefault("allow_from", ["tailscale", "lan"])
# 기기 고유 ID — 한 번 생기면 불변(재설치해도 보존). 이름은 사람이 고치면 그대로 둔다.
dev = cfg.setdefault("device", {})
if not dev.get("id"):
    dev["id"] = os.environ["DEVICE_ID"]
    print("기기 ID 생성:", dev["id"])
dev.setdefault("name", os.environ["DEVICE_NAME"])
ime = cfg.setdefault("ime_sync", {})
ime.setdefault("enabled", True)
ime.setdefault("heartbeat_sec", 0)     # ⚠ 기본 끔 — 재적용이 한글 조합을 깨는 역효과 확인(2026-08-06)
ime.setdefault("auto_recover", True)   # 자동정정 시 포커스 바운스까지(꼬인 세션 리셋). 끄면 IME 정렬만
if "only_app" not in ime:
    ime["only_app"] = os.environ["ONLY_APP"]
# 강제 정렬 핫키 — Ctrl+Space 대체(그건 호스트만 바꿔 어긋남을 만든다). 조합은 자유롭게 수정.
cfg.setdefault("hotkeys", [{"combo": "ctrl+opt+shift+k", "action": "realign"}])

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.chmod(path, 0o600)   # 토큰이 들어 있다
PY

echo "설정: $CFG"

# ---------- 빌드 ----------
echo "빌드 중..."
# ⚠ top-level 실행문이 있는 파일은 다중 파일 빌드에서 반드시 main.swift 여야 한다
#   (다른 이름이면 "statements are not allowed at the top level" — 실증 2026-08-07)
# 개발 빌드는 이 기기 아키텍처만 만든다(배포본은 package_app.sh 가 universal 로).
# 다만 -target 의 배포 타깃은 배포본과 같게 맞춘다 — 그래야 macOS 13 에 없는 API 를
# 쓰면 여기서 바로 컴파일 에러가 난다. 안 맞추면 호스트 OS 버전이 박혀서,
# 개발 기기에선 멀쩡하고 배포 후 남의 맥에서만 안 뜨는 상태가 된다.
source "$SRC_DIR/scripts/build-config.sh"
swiftc -O -target "$(uname -m)-apple-macos$MIN_MACOS" \
    -o "$SRC_DIR/macbridge" "$SRC_DIR/main.swift" "$SRC_DIR"/src/*.swift

# ⚠ 실행 중인 바이너리를 cp 로 덮어쓰면 코드 서명이 깨져 다음 실행이 SIGKILL 로 죽는다
#   (Taskgated Invalid Signature). 반드시 먼저 내리고 → rm → cp → 재서명.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$BAR_LABEL" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true
mkdir -p "$BIN_DIR"
rm -f "$BIN"
cp "$SRC_DIR/macbridge" "$BIN"
codesign -f -s - "$BIN" 2>/dev/null || true
chmod +x "$BIN"
codesign -v "$BIN" 2>/dev/null && echo "설치: $BIN (서명 유효)" || echo "설치: $BIN (⚠ 서명 검증 실패)"

# ---------- v0 정리 ----------
if [ -f "$OLD_PLIST" ] || [ -f "$OLD_BIN" ]; then
    launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true
    pkill -f "$OLD_BIN" 2>/dev/null || true
    rm -f "$OLD_PLIST" "$OLD_BIN"
    echo "정리: 옛 ime-sync 데몬을 내리고 제거했습니다 (같은 포트를 두 데몬이 물지 않도록)"
fi

# ---------- LaunchAgent ----------
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# ---------- 메뉴바 LaunchAgent ----------
# 데몬과 별개 프로세스다 — UI 가 죽어도 IME 동기화는 계속 돈다.
#
# ⚠ .app 이 설치돼 있으면 여기서 띄우면 안 된다 — **메뉴바 아이콘이 2개가 된다**(2026-08-08 실사용).
#   앱은 자기가 메뉴바를 띄우고 시작할 때 이 에이전트를 제거하지만(AppEnvironment.swift),
#   그 뒤에 install.sh 를 돌리면 되살아난다. 앱은 install.sh 를 모르고 install.sh 는 앱을 몰랐다.
#   앱이 있으면 앱이 권위다 — 여기서는 등록하지 않고 남은 흔적을 치운다.
if [ -d "/Applications/MacBridge.app" ]; then
    launchctl bootout "gui/$(id -u)/$BAR_LABEL" 2>/dev/null || true
    rm -f "$BAR_PLIST"
    echo "ℹ MacBridge.app 이 설치돼 있어 메뉴바는 앱이 담당합니다 (별도 에이전트 등록 안 함)"
else
cat > "$BAR_PLIST" <<BAR_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BAR_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
        <string>menubar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG}</string>
    <key>StandardErrorPath</key>
    <string>${LOG}</string>
</dict>
</plist>
BAR_EOF

launchctl bootout "gui/$(id -u)/$BAR_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$BAR_PLIST"
fi

# ---------- 방화벽(ALF) 확인 ----------
# ⚠ 실제로 밟은 함정: 방화벽이 켜져 있으면 이 데몬의 **외부 수신만** 조용히 막힌다.
#   루프백은 통과하므로 자기 테스트는 멀쩡히 성공해 원인을 놓치기 쉽다.
#   백그라운드 LaunchAgent 라 "수신 허용?" 팝업을 사람이 볼 수 없어 사실상 거부로 굳는다.
if [ "$MODE" != "watch" ]; then
    ALF=/usr/libexec/ApplicationFirewall/socketfilterfw
    ALF_STATE="$("$ALF" --getglobalstate 2>/dev/null || echo "")"
    case "$ALF_STATE" in
        *enabled*)
            if ! "$ALF" --listapps 2>/dev/null | grep -q "$BIN"; then
                echo
                echo "⚠ 방화벽이 켜져 있는데 macbridge 가 허용 목록에 없습니다 — 외부에서 오는 알림이 막힙니다."
                echo "  (루프백 테스트는 통과하므로 증상이 '아무 로그도 안 남음'으로만 나타납니다)"
                echo "  아래 두 줄을 실행하세요:"
                echo
                echo "    sudo $ALF --add $BIN"
                echo "    sudo $ALF --unblockapp $BIN"
                echo
            fi
            ;;
    esac
fi

echo
echo "✅ 등록 완료"
"$BIN" config
echo
echo "   로그: $LOG"
if [ -d "/Applications/MacBridge.app" ]; then
    echo "확인: launchctl list | grep macbridge   (데몬 1개 — 메뉴바는 앱이 띄운다)"
else
    echo "확인: launchctl list | grep macbridge   (데몬 + 메뉴바 2개)"
fi
echo "      tail -f $LOG"
echo
echo "⚠ 다른 기기의 config.json 에도 같은 token 을 넣어야 합니다."
