# 빌드 공통 상수 — install.sh 와 scripts/package_app.sh 가 함께 읽는다.
# (실행용이 아니라 source 전용)
#
# ⚠ MIN_MACOS 는 세 곳이 반드시 같아야 한다:
#     ① swiftc -target 의 배포 타깃   → 바이너리가 실제로 요구하는 최소 버전
#     ② Info.plist LSMinimumSystemVersion → Finder 가 읽어 경고를 띄우는 값
#     ③ 홈페이지·README 의 "macOS N 이상" 표기
#
#   ①을 빼먹으면 swiftc 가 빌드한 맥의 OS 버전을 그대로 박아 넣는다.
#   실제로 minos 26.0 인 바이너리에 plist 만 13.0 이라 적혀 나간 적이 있다
#   (2026-08-08 발견). plist 는 거짓말을 해도 조용하지만 바이너리는 그냥 안 뜬다.
#   그래서 여기 한 곳에서만 정의하고 양쪽이 가져다 쓴다.
MIN_MACOS="13.0"

# 배포본은 Intel 맥도 받는다. "새 맥 사고 남은 구형 맥을 원격으로 쓴다"가
# 이 앱의 대표 사용례라, Intel 을 빼면 잠재 사용자와 정확히 겹치는 층이 날아간다.
UNIVERSAL_ARCHS=(arm64 x86_64)
