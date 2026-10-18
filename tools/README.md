# tools

## set-ime.swift — 드리프트 회귀 테스트용

macbridge 를 **거치지 않고** 입력 소스를 바꾼다. "다른 무언가가 입력 소스를 바꿨을 때
macbridge 가 정정하는가"를 재현하기 위한 것.

```bash
swiftc -O -o /tmp/set-ime tools/set-ime.swift

# 회귀 테스트: 드리프트시킨 뒤 같은 값을 보내면 정정돼야 한다
TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/macbridge/config.json')))['token'])")
send() { python3 -c "
import socket,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
s.sendto(('$TOKEN $1 '+str(int(time.time()*1000))).encode(),('127.0.0.1',8765))"; }

send ko            # ① macbridge 로 ko 적용
/tmp/set-ime en    # ② 외부에서 몰래 en 으로 드리프트
send ko            # ③ 같은 ko 를 다시 → **정정돼야 한다**
macbridge status   # ko 여야 통과
```

⚠ 2026-08-06 이전 빌드는 ③에서 **아무 로그도 없이 무시**했다(자소분리 고착의 원인).
