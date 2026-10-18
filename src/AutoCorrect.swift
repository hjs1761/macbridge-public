import Foundation

// MARK: - 자동정정 (자동복구)
//
// 피어가 state 메시지로 "나는 지금 X다"라고 보고했는데 내 언어와 다르면,
// **뷰어를 띄운 기기(드라이빙)** 가 자기 언어를 재전송해 불일치를 스스로 없앤다.
// 불일치 상태에서 타이핑할 때 입력 세션이 꼬여 자소분리가 고착되므로(2026-08-07 규명),
// 불일치의 수명을 1초 안쪽으로 줄이는 것이 곧 자소분리 예방이다.
//
// ⚠ 2026-08-06 하트비트 사고와의 차이 — 그때는 **맹목적 주기 재적용**이었다.
//   여기서는 ①상대가 자기 입으로 "다르다"고 보고한 경우에만 ②수신측 실상태 가드가
//   같은 값 재적용(=조합 리셋)을 걸러 주는 전제 위에서 ③레이트리밋을 걸고 보낸다.

/// 정정을 보낼지의 순수 판정. 라이브 상태는 호출부가 읽어서 넘긴다(테스트 가능하도록).
func shouldAutoCorrect(myLang: String?, peerLang: String, driving: Bool,
                       suppressed: Bool, directedByPeer: Bool, msSinceLast: Int64) -> Bool {
    guard let my = myLang, ["ko", "en"].contains(my) else { return false }
    guard peerLang != my else { return false }
    guard driving else { return false }              // 권한자 = 뷰어 최전면 기기뿐
    guard !suppressed else { return false }          // 수신 직후엔 침묵(에코 방지)
    guard !directedByPeer else { return false }      // 나를 지시하는 쪽은 건드리지 않는다(역류방지)
    guard msSinceLast >= 2_000 else { return false } // 폭주 방지
    return true
}

/// 상대가 **혼자** 언어를 바꿨을 때, 되돌리는 대신 **따라갈 것인가.**
///
/// ⚠ 배경(2026-08-08 실측) — Jump Desktop 에서 `Ctrl+Space` 는 뷰어가 삼켜 **호스트만** 바꾼다.
///   그러면 클라(권한자)가 "어긋났다"고 보고 recover 로 되돌려서, 사용자 눈에는
///   **"깜빡이더니 그대로"** 로 보인다 — macbridge 가 한영전환을 취소하는 셈이었다.
///   `Ctrl+Space` 를 쓰던 사람에게는 이 도구가 방해물이 된다.
///
///   의도의 주체는 **"누가 방금 바뀌었나"** 다. 내가 가만히 있는데 상대만 바뀌었다면
///   그건 사용자가 상대 쪽에서 전환한 것이므로, 되돌릴 게 아니라 내가 맞춰 가야 한다.
///
/// - Parameter peerJustChanged: 이번 보고가 **전이**인가(직전 기록과 언어가 달라졌는가).
///   정체된 불일치(잠긴 기기가 계속 en 을 보고하는 것 등)를 따라가면 안 되므로 반드시 필요하다.
/// - Parameter msSinceMyChange: 내가 마지막으로 **스스로** 바꾼 뒤 지난 시간.
func shouldFollowPeer(myLang: String?, peerLang: String, peerJustChanged: Bool,
                      driving: Bool, suppressed: Bool, msSinceMyChange: Int64) -> Bool {
    guard let my = myLang, ["ko", "en"].contains(my) else { return false }
    guard ["ko", "en"].contains(peerLang), peerLang != my else { return false }
    guard peerJustChanged else { return false }   // 정체된 불일치는 의도가 아니다
    guard driving else { return false }           // 원격 세션 중에만 — 로컬 작업 중엔 남을 안 따른다
    guard !suppressed else { return false }       // 수신 직후 에코 창
    guard msSinceMyChange >= 3_000 else { return false }  // 내가 방금 바꿨다면 주체는 나다
    return true
}

/// 이 피어에게 지금 정정을 보내도 되는가. **반드시 피어별 이력으로 판정한다.**
///
/// ⚠ **전역 레이트리밋 starvation**(2026-08-07 실측) — 잠금 화면 기기가 5초마다 슬롯을 먹어
/// 정작 사람이 쓰는 호스트가 정정을 **한 번도 못 받았다**. 그래서 이력을 피어별로 나눈다.
///
/// ⚠ 여기서 막는 건 **폭주뿐**이다. "이 피어는 고쳐도 소용없다"는 판정은 결과 기반
/// (연속 무효 횟수)으로 `noteState` 가 한다 — 시도 횟수로 세면 **사용자가 `Ctrl+Space` 로
/// 반복해 어긋내는 정상 사용까지 막혀 버린다**(실측: 4회 만에 억제돼 복구가 안 됐다).
///
/// - Parameter recentMs: 그 피어에게 최근 보낸 정정 시각들(오름차순)
func correctionAllowed(recentMs: [Int64], now: Int64,
                       minGapMs: Int64 = 2_000,
                       burstWindowMs: Int64 = 60_000,
                       burstLimit: Int = 30) -> Bool {
    if let last = recentMs.last, now - last < minGapMs { return false }
    return recentMs.filter { now - $0 <= burstWindowMs }.count < burstLimit
}
