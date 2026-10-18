import Foundation
import AppKit

/// 자소분리 관측용 입력 창.
///
/// 자기 앱의 자기 텍스트뷰를 읽으므로 **권한이 필요 없다**(키로거가 아니다).
/// 자소분리를 감지하면 그 순간의 피어 상태를 함께 남긴다 — 그게 이 도구의 존재 이유다.
/// 피어 상태는 로컬 데몬에게 UDP `query` 로 물어서 얻는다(keepalive 는 데몬 포트로만 온다).
final class ProbeController: NSObject, NSTextViewDelegate {
    private let cfg: Config
    private var window: NSWindow!
    private var textView: NSTextView!
    private var statusLabel: NSTextField!
    private var lastReported = ""

    init(config: Config) {
        self.cfg = config
        super.init()
    }

    func show() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "macbridge probe — 여기에 한글을 쳐 보세요"
        window.center()

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 52, width: 496, height: 130))
        textView = NSTextView(frame: scroll.bounds)
        textView.font = NSFont.systemFont(ofSize: 18)
        textView.delegate = self
        textView.isRichText = false
        scroll.documentView = textView
        scroll.hasVerticalScroller = true

        statusLabel = NSTextField(labelWithString: "대기 중")
        statusLabel.frame = NSRect(x: 12, y: 16, width: 496, height: 24)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(statusLabel)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)   // 창 뜨자마자 클릭 없이 바로 입력
        NSApp.activate(ignoringOtherApps: true)
    }

    func textDidChange(_ notification: Notification) {
        // 조합 **중**인 글자는 정상적으로도 낱자로 보이므로 제외한다.
        let full = textView.string
        let marked = textView.markedRange()
        let confirmed: String
        if marked.location != NSNotFound, marked.length > 0,
           let r = Range(NSRange(location: 0, length: marked.location), in: full) {
            confirmed = String(full[r])
        } else {
            confirmed = full
        }

        let n = detachedJamoCount(confirmed)
        if n == 0 {
            statusLabel.stringValue = "정상 — 낱자 0개"
            statusLabel.textColor = .secondaryLabelColor
            return
        }
        statusLabel.stringValue = "🔴 자소분리 — 낱자 \(n)개"
        statusLabel.textColor = .systemRed

        // 같은 내용으로 중복 기록하지 않는다
        guard confirmed != lastReported else { return }
        lastReported = confirmed

        let jamo = String(confirmed.unicodeScalars.filter {
            (0x3131...0x318E).contains(Int($0.value))
        }.map(Character.init))
        log("🔴 자소분리 — 낱자 \(n)개 \"\(jamo)\"")

        // 그 순간의 피어 상태를 데몬에게 물어 함께 남긴다.
        let mine = currentLanguage() ?? "?"
        if let r = queryDaemon(cfg, timeout: 0.3), !r.peers.isEmpty {
            let online = r.peers.filter(\.isOnline)
            let desc = r.peers.map { "\($0.name) \($0.isOnline ? $0.lang : "(오프라인)")" }
                .joined(separator: " · ")
            log("  그 순간: 나 \(mine) · \(desc)")
            if !online.isEmpty, online.allSatisfy({ $0.lang == mine }) {
                log("  → 전부 일치인데도 발생 (= IME 불일치 외 원인)")
            }
        } else {
            log("  그 순간: 나 \(mine) · (상대 상태 없음 — 데몬 미응답이거나 피어 keepalive 미수신)")
        }
    }
}
