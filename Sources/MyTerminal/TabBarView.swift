import AppKit

/// 터미널 위에 붙는 탭바.
///
/// 색은 사이드바와 같은 `ChromeColors`에서 가져온다 — 탭바가 터미널 배경과
/// 다른 색으로 뜨면 창 안에 창이 하나 더 있는 것처럼 보인다. macOS 기본
/// 세그먼트 컨트롤을 쓰지 않는 이유도 같다: 그건 시스템 강조색을 따라가서
/// 테마를 무시한다.
@MainActor
final class TabBarView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNew: (() -> Void)?

    static let preferredHeight: CGFloat = 30

    private let stack = NSStackView()
    private let newButton = NSButton()
    private var theme: AppTheme = .ghosttyDefault
    private var colors: ChromeColors = AppTheme.ghosttyDefault.chrome(systemIsDark: false)
    private var group = TabGroup()
    private var heightConstraint: NSLayoutConstraint?

    /// 감춘 탭바가 자리를 차지하지 않게 높이까지 접는다. 오토레이아웃은
    /// `isHidden`만으로는 공간을 회수하지 않는다.
    override var isHidden: Bool {
        didSet { heightConstraint?.constant = isHidden ? 0 : Self.preferredHeight }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        newButton.title = "+"
        newButton.bezelStyle = .accessoryBarAction
        newButton.isBordered = false
        newButton.font = .systemFont(ofSize: 15, weight: .light)
        newButton.target = self
        newButton.action = #selector(addTab(_:))
        newButton.translatesAutoresizingMaskIntoConstraints = false
        newButton.toolTip = "새 탭 (⌘T)"
        addSubview(newButton)

        let height = heightAnchor.constraint(equalToConstant: Self.preferredHeight)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: newButton.leadingAnchor, constant: -4),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 갱신

    func reload(_ group: TabGroup) {
        self.group = group
        rebuild()
    }

    /// 해석한 색 대신 테마를 받는다. 시스템 라이트/다크를 따라가는 테마는
    /// 외관이 바뀔 때마다 색이 달라지므로 여기서 다시 계산한다 —
    /// `ProjectSidebarViewController.apply(theme:)`와 같은 이유다.
    func apply(theme: AppTheme) {
        self.theme = theme
        refreshColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        colors = theme.chrome(systemIsDark: isDark)
        layer?.backgroundColor = colors.background.cgColor
        newButton.contentTintColor = colors.foreground.withAlphaComponent(0.7)
        rebuild()
    }

    private func rebuild() {
        for view in stack.views {
            stack.removeView(view)
        }
        for tab in group.tabs {
            let item = TabItemView(
                title: tab.title,
                isActive: tab.id == group.activeTabID,
                paneCount: tab.sessions.count,
                colors: colors
            )
            item.onSelect = { [weak self] in self?.onSelect?(tab.id) }
            item.onClose = { [weak self] in self?.onClose?(tab.id) }
            stack.addView(item, in: .leading)
        }
    }

    @objc private func addTab(_: Any?) {
        onNew?()
    }

    /// 탭바 아래에 경계선을 그어 터미널과 구분한다. 같은 배경색을 쓰기 때문에
    /// 선이 없으면 어디까지가 탭바인지 알 수 없다.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        colors.foreground.withAlphaComponent(0.12).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

// MARK: - 탭 하나

/// 탭 조각. 제목과 닫기 버튼을 들고 있고, 클릭은 뷰 전체에서 받는다 —
/// 버튼으로 만들면 제목이 길 때 잘리는 자리에서 클릭이 먹지 않는다.
@MainActor
private final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let isActive: Bool
    private let colors: ChromeColors

    init(title: String, isActive: Bool, paneCount: Int, colors: ChromeColors) {
        self.isActive = isActive
        self.colors = colors
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = isActive
            ? colors.selection.cgColor
            : NSColor.clear.cgColor

        // 분할한 탭은 pane 개수를 붙여 준다. 탭만 봐도 안에 몇 개가 있는지 알 수 있다.
        label.stringValue = paneCount > 1 ? "\(title) (\(paneCount))" : title
        label.font = .systemFont(ofSize: 11, weight: isActive ? .medium : .regular)
        label.textColor = isActive
            ? colors.foreground
            : colors.foreground.withAlphaComponent(0.6)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        closeButton.title = "×"
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 12)
        closeButton.contentTintColor = colors.foreground.withAlphaComponent(0.55)
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualTo: label.widthAnchor, constant: 38),
            widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        // 가운데 클릭으로 닫는 관례는 그대로 두고, 왼쪽 클릭은 선택.
        if event.buttonNumber == 2 {
            onClose?()
            return
        }
        onSelect?()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        onClose?()
    }

    @objc private func close(_: Any?) {
        onClose?()
    }
}
