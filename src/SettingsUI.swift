import AppKit

// MARK: - 설정 창 공용 부품
//
// 한 줄을 세 자리로 고정한다 —  [아이콘] [제목 / 설명] ……… [컨트롤]
// 눈이 왼쪽에서 이름을, 오른쪽에서 상태를 읽으면 되므로 훑기가 쉬워진다.
//
// ⚠ **폭은 반드시 물려받는다.** 처음엔 모든 행을 540 으로 고정했는데, 카드 안쪽은
//   좌우 여백(14×2)을 뺀 512 라 행이 28pt 씩 삐져나가 글자가 겹치고 버튼이 잘렸다.
//   그래서 `width` 를 인자로 내려보내고, 카드는 자기 안쪽 폭을 자식에게 준다.
//
// ⚠ NSBox 는 contentView 높이를 스스로 못 잡아 빈 공간이 크게 남았다.
//   카드는 `CardView`(직접 그리는 NSView) + 제약으로 바꿔 내용 높이에 딱 맞게 한다.
//   색도 NSColor 로 그리므로 다크/라이트 전환이 자동으로 따라온다.

/// 탭 본문의 기준 폭. 창 600 − 탭 여백 − 스택 여백.
let uiContentWidth: CGFloat = 528
/// 카드 안쪽 여백
private let cardPad: CGFloat = 14

/// 섹션 제목.
func uiSection(_ title: String, topGap: CGFloat = 14) -> NSView {
    let l = NSTextField(labelWithString: title)
    l.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    l.textColor = .secondaryLabelColor
    let box = NSStackView(views: [l])
    box.orientation = .vertical
    box.alignment = .leading
    box.edgeInsets = NSEdgeInsets(top: topGap, left: 0, bottom: 0, right: 0)
    return box
}

/// 위에서 아래로 쌓이는 좌표계. 스크롤 문서 뷰에 쓴다.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 하단 도구줄 바탕. 본문과 살짝 다른 색을 깔아 **다른 층**임을 알린다.
final class FooterView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.black.withAlphaComponent(0.06).setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// 배경과 테두리를 직접 그린다 — 시스템 색을 쓰므로 테마 전환이 자동이다.
private final class CardView: NSView {
    var accent = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        (accent ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                : NSColor.textBackgroundColor.withAlphaComponent(0.45)).setFill()
        p.fill()
        (accent ? NSColor.controlAccentColor.withAlphaComponent(0.45)
                : NSColor.separatorColor).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

/// 배경이 깔린 카드. 안쪽 폭을 자식에게 물려주려면 `uiCardInnerWidth` 를 쓴다.
func uiCard(_ views: [NSView], accent: Bool = false,
            width: CGFloat = uiContentWidth) -> NSView {
    let inner = NSStackView(views: views)
    inner.orientation = .vertical
    inner.alignment = .leading
    inner.spacing = 6
    inner.translatesAutoresizingMaskIntoConstraints = false

    let card = CardView()
    card.accent = accent
    card.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(inner)
    NSLayoutConstraint.activate([
        card.widthAnchor.constraint(equalToConstant: width),
        inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: cardPad),
        inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -cardPad),
        inner.topAnchor.constraint(equalTo: card.topAnchor, constant: cardPad),
        inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -cardPad),
    ])
    return card
}

/// 카드 안쪽에서 쓸 수 있는 폭.
func uiCardInnerWidth(_ outer: CGFloat = uiContentWidth) -> CGFloat { outer - cardPad * 2 }

/// SF Symbol 아이콘. 없는 이름이면 빈 자리로 둔다(글자를 지어내지 않는다).
private func uiIcon(_ symbol: String?) -> NSView {
    let v = NSImageView()
    v.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        v.widthAnchor.constraint(equalToConstant: 20),
        v.heightAnchor.constraint(equalToConstant: 20),
    ])
    if let s = symbol {
        v.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)
        v.contentTintColor = .secondaryLabelColor
        v.imageScaling = .scaleProportionallyUpOrDown
    }
    return v
}

/// 여러 줄로 접히는 설명 라벨. **폭을 명시해야** 줄바꿈 위치가 정해지고 높이가 잡힌다.
func uiWrapLabel(_ text: String, width: CGFloat, size: CGFloat = 11,
                 secondary: Bool = true) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = NSFont.systemFont(ofSize: size)
    if secondary { l.textColor = .secondaryLabelColor }
    l.translatesAutoresizingMaskIntoConstraints = false
    l.preferredMaxLayoutWidth = width
    l.widthAnchor.constraint(equalToConstant: width).isActive = true
    l.setContentCompressionResistancePriority(.required, for: .vertical)
    return l
}

/// 한 줄 = [아이콘] [제목/설명] ……… [오른쪽 컨트롤]
///
/// - Parameter width: 이 행이 차지할 전체 폭. **카드 안이라면 `uiCardInnerWidth()` 를 넘긴다.**
/// - Parameter trailingWidth: 오른쪽 컨트롤에 남겨 둘 자리. 텍스트는 그만큼 좁게 접힌다.
func uiRow(icon: String? = nil, title: String, detail: String? = nil,
           trailing: NSView? = nil, width: CGFloat = uiContentWidth,
           trailingWidth: CGFloat = 120) -> NSView {
    let iconW: CGFloat = 20, gap: CGFloat = 10
    let reserve = trailing == nil ? 0 : trailingWidth + gap
    let textW = max(120, width - iconW - gap - reserve)

    let t = NSTextField(labelWithString: title)
    t.font = NSFont.systemFont(ofSize: 13)
    t.translatesAutoresizingMaskIntoConstraints = false
    t.widthAnchor.constraint(lessThanOrEqualToConstant: textW).isActive = true

    var textViews: [NSView] = [t]
    if let d = detail, !d.isEmpty { textViews.append(uiWrapLabel(d, width: textW)) }
    let textBox = NSStackView(views: textViews)
    textBox.orientation = .vertical
    textBox.alignment = .leading
    textBox.spacing = 2
    textBox.translatesAutoresizingMaskIntoConstraints = false
    textBox.widthAnchor.constraint(equalToConstant: textW).isActive = true

    var views: [NSView] = [uiIcon(icon), textBox]
    if let tr = trailing {
        tr.translatesAutoresizingMaskIntoConstraints = false
        // 컨트롤이 텍스트 자리를 침범하지 않게 상한을 준다 — 넘치면 잘린다
        tr.widthAnchor.constraint(lessThanOrEqualToConstant: trailingWidth).isActive = true
        tr.setContentHuggingPriority(.required, for: .horizontal)
        views.append(tr)
    }
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = gap
    row.distribution = .fill
    row.translatesAutoresizingMaskIntoConstraints = false
    row.widthAnchor.constraint(equalToConstant: width).isActive = true
    return row
}

/// 체크박스 대신 스위치. **켬/끔이 멀리서도 보인다.**
func uiSwitch(on: Bool, owner c: SettingsWindowController,
              _ onToggle: @escaping (Bool) -> Void) -> NSView {
    let t = ActionTarget { sender in
        guard let s = sender as? NSSwitch else { return }
        onToggle(s.state == .on)
    }
    c.retained.append(t)
    let sw = NSSwitch()
    sw.state = on ? .on : .off
    sw.target = t
    sw.action = #selector(ActionTarget.fire(_:))
    return sw
}

func uiButton(_ title: String, owner c: SettingsWindowController,
              _ onClick: @escaping () -> Void) -> NSButton {
    let t = ActionTarget { _ in onClick() }
    c.retained.append(t)
    let b = NSButton(title: title, target: t, action: #selector(ActionTarget.fire(_:)))
    b.bezelStyle = .rounded
    b.setContentHuggingPriority(.required, for: .horizontal)
    return b
}

/// 세로 스택 기본형.
func uiStack() -> NSStackView {
    let s = NSStackView()
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = 10
    s.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 20, right: 22)
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

/// 스크롤 가능한 탭 본문. 내용이 길어져도 잘리지 않는다.
///
/// ⚠ 문서 뷰 높이를 **내용에 맞춰** 정해야 한다. 고정 프레임으로 두면 아래가 잘리거나
///   빈 공간이 남는다. 그리고 스크롤은 **맨 위에서** 시작해야 한다(기본은 아래다).
func uiScrollPane(_ stack: NSStackView) -> NSView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.autohidesScrollers = true
    scroll.autoresizingMask = [.width, .height]

    // ⚠ 문서 뷰는 **뒤집어야** 한다. 맥의 기본 좌표계는 왼쪽 아래가 원점이라,
    //   내용이 짧으면 위가 아니라 **바닥에 붙는다** — 위쪽에 큰 공백이 생긴 원인이 이것이다.
    let doc = FlippedView()
    doc.translatesAutoresizingMaskIntoConstraints = false
    doc.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
        stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
        stack.topAnchor.constraint(equalTo: doc.topAnchor),
        stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
    ])
    scroll.documentView = doc
    doc.widthAnchor.constraint(equalToConstant: uiContentWidth + 44).isActive = true

    DispatchQueue.main.async {
        doc.layoutSubtreeIfNeeded()
        scroll.documentView?.scroll(NSPoint(x: 0, y: 0))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
    }
    return scroll
}
