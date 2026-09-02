import AppKit

/// 탭 하나의 pane 배치를 화면에 옮긴다. `SplitTree`가 정한 구조대로
/// `NSSplitView`를 중첩해 만들고, 세션 뷰는 재사용한다.
///
/// pane마다 컨테이너를 하나씩 두고 세션 뷰는 그 안에 붙박이로 둔다. 분할이
/// 바뀔 때 옮겨 다니는 것은 컨테이너뿐이다 — 세션 뷰를 직접 옮겨도 surface는
/// 살아 있지만(창에서 빠지면 디스플레이 링크만 멈춘다), 컨테이너를 두면 포커스
/// 테두리를 그릴 자리가 생기고 제약 조건을 매번 다시 걸 필요도 없다.
@MainActor
final class SplitLayoutView: NSView {
    private var installedLayout: SplitTree<UUID>?
    /// 실제로 화면에 올라간 pane. 배치가 그대로여도 세션이 나중에 생기는
    /// 경우가 있어서(복원한 탭은 처음 열 때 셸을 띄운다) 따로 본다.
    private var renderedPanes: Set<UUID> = []
    private var panes: [UUID: PaneContainerView] = [:]
    private var colors: ChromeColors = AppTheme.ghosttyDefault.chrome(systemIsDark: false)

    /// 배치를 반영한다. 구조와 올라간 pane이 그대로면 다시 만들지 않는다 —
    /// 다시 만들면 사용자가 끌어 놓은 분할선 위치가 매번 초기화된다.
    func apply(layout: SplitTree<UUID>, sessions: [UUID: TerminalSession], focused: UUID?) {
        let available = Set(layout.leaves.filter { sessions[$0] != nil })
        if installedLayout != layout || renderedPanes != available {
            installedLayout = layout
            rebuild(layout, sessions: sessions)
        }
        let hasSiblings = layout.leaves.count > 1
        for (id, pane) in panes {
            pane.setFocused(hasSiblings && id == focused, colors: colors)
        }
    }

    func apply(colors: ChromeColors) {
        self.colors = colors
        for (_, pane) in panes {
            pane.refresh(colors: colors)
        }
        for split in splitViews(in: self) {
            split.dividerTint = colors.foreground.withAlphaComponent(0.15)
            split.needsDisplay = true
        }
    }

    /// 입력 상자를 그 pane 아래에 붙인다. `paneID`가 nil이면 어디에도 붙이지
    /// 않는다. 상자는 창에 하나뿐이라 포커스가 옮겨 갈 때마다 옮겨 붙는다.
    func attachComposer(_ composer: NSView?, to paneID: UUID?) {
        for (id, pane) in panes where id != paneID {
            pane.attach(nil)
        }
        guard let paneID, let pane = panes[paneID] else { return }
        pane.attach(composer)
    }

    /// 이 배치에서 빠진 pane의 컨테이너를 버린다. 세션 자체를 치우는 것은
    /// 창이 한다 — 여기서는 화면에서만 뗀다.
    func discardPanes(except keep: Set<UUID>) {
        for (id, pane) in panes where !keep.contains(id) {
            pane.removeFromSuperview()
            panes.removeValue(forKey: id)
        }
    }

    private func rebuild(_ layout: SplitTree<UUID>, sessions: [UUID: TerminalSession]) {
        for subview in subviews {
            subview.removeFromSuperview()
        }
        renderedPanes = Set(layout.leaves.filter { sessions[$0] != nil })
        guard let root = makeView(for: layout, sessions: sessions) else { return }
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        discardPanes(except: Set(layout.leaves))
    }

    private func makeView(
        for node: SplitTree<UUID>,
        sessions: [UUID: TerminalSession]
    ) -> NSView? {
        switch node {
        case let .leaf(id):
            guard let session = sessions[id] else { return nil }
            return pane(for: session)

        case let .branch(axis, children):
            let arranged = children.compactMap { makeView(for: $0, sessions: sessions) }
            guard !arranged.isEmpty else { return nil }
            guard arranged.count > 1 else { return arranged[0] }

            let split = ThemedSplitView()
            // 좌우로 나란히 놓으려면 분할선이 세로로 서야 한다 — AppKit의
            // `isVertical`은 pane 배치가 아니라 분할선 방향을 말한다.
            split.isVertical = axis == .horizontal
            split.dividerStyle = .thin
            split.dividerTint = colors.foreground.withAlphaComponent(0.15)
            for view in arranged {
                // NSSplitView는 프레임으로 자식을 배치한다. 여기서 제약으로
                // 넘기면 오토레이아웃이 프레임을 덮어써 pane이 접힌다.
                view.translatesAutoresizingMaskIntoConstraints = true
                split.addArrangedSubview(view)
            }
            return split
        }
    }

    private func pane(for session: TerminalSession) -> PaneContainerView {
        if let existing = panes[session.id] { return existing }
        let container = PaneContainerView(content: session.view)
        panes[session.id] = container
        return container
    }

    private func splitViews(in view: NSView) -> [ThemedSplitView] {
        view.subviews.flatMap { subview -> [ThemedSplitView] in
            let nested = splitViews(in: subview)
            return (subview as? ThemedSplitView).map { [$0] + nested } ?? nested
        }
    }
}

// MARK: - pane 컨테이너

/// pane 하나를 담는 자리. 포커스를 가진 pane에 테두리를 그린다.
@MainActor
private final class PaneContainerView: NSView {
    private var isFocused = false
    private let content: NSView
    /// 터미널의 아래쪽 경계. 입력 상자가 붙으면 상자 위로 올라간다.
    private var contentBottom: NSLayoutConstraint
    private weak var composer: NSView?

    init(content: NSView) {
        self.content = content
        contentBottom = NSLayoutConstraint()
        super.init(frame: .zero)
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        contentBottom = content.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentBottom,
        ])
    }

    func attach(_ composer: NSView?) {
        guard self.composer !== composer else { return }
        if let current = self.composer, current.superview === self {
            current.removeFromSuperview()
        }
        self.composer = composer
        contentBottom.isActive = false

        guard let composer else {
            contentBottom = content.bottomAnchor.constraint(equalTo: bottomAnchor)
            contentBottom.isActive = true
            return
        }

        composer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(composer)
        contentBottom = content.bottomAnchor.constraint(equalTo: composer.topAnchor)
        NSLayoutConstraint.activate([
            contentBottom,
            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFocused(_ focused: Bool, colors: ChromeColors) {
        isFocused = focused
        refresh(colors: colors)
    }

    /// pane이 하나뿐일 때는 테두리를 그리지 않는다. 나눠 놓지도 않은 화면에
     /// 강조 테두리가 뜨면 창이 잘못 그려진 것처럼 보인다.
    func refresh(colors: ChromeColors) {
        layer?.borderWidth = isFocused ? 1 : 0
        layer?.borderColor = isFocused ? colors.selection.cgColor : nil
    }
}

// MARK: - 분할선

/// 분할선을 테마 색으로 그리는 `NSSplitView`.
///
/// 처음 크기를 받을 때 한 번만 pane을 균등하게 나눈다. 매번 나누면 사용자가
/// 끌어 놓은 분할선이 창 크기를 바꿀 때마다 제자리로 돌아간다.
@MainActor
private final class ThemedSplitView: NSSplitView {
    var dividerTint: NSColor = .separatorColor

    private var didDistribute = false

    override var dividerColor: NSColor { dividerTint }

    override func layout() {
        super.layout()
        guard
            !didDistribute,
            arrangedSubviews.count > 1,
            bounds.width > 1,
            bounds.height > 1
        else { return }
        didDistribute = true
        distributeEvenly()
    }

    /// 분할선 위치를 직접 옮긴다. 자식 프레임을 써 놓고 `adjustSubviews()`를
    /// 부르는 방법은 통하지 않는다 — NSSplitView가 이전 비율을 기준으로 다시
    /// 나누기 때문에, 새로 끼운 pane이 폭 0으로 남고 먼저 있던 pane이 전부
    /// 가져간다.
    private func distributeEvenly() {
        let count = arrangedSubviews.count
        guard count > 1 else { return }

        let total = isVertical ? bounds.width : bounds.height
        let usable = total - dividerThickness * CGFloat(count - 1)
        let slice = usable / CGFloat(count)
        for index in 0 ..< (count - 1) {
            let offset = (slice + dividerThickness) * CGFloat(index) + slice
            setPosition(offset, ofDividerAt: index)
        }
    }
}
