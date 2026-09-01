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
    private var panes: [UUID: PaneContainerView] = [:]
    private var colors: ChromeColors = AppTheme.ghosttyDefault.chrome(systemIsDark: false)

    /// 배치를 반영한다. 구조가 그대로면 다시 만들지 않는다 — 다시 만들면
    /// 사용자가 끌어 놓은 분할선 위치가 매번 초기화된다.
    func apply(layout: SplitTree<UUID>, sessions: [UUID: TerminalSession], focused: UUID?) {
        if installedLayout != layout {
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

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    private func distributeEvenly() {
        let count = CGFloat(arrangedSubviews.count)
        let dividers = dividerThickness * (count - 1)
        if isVertical {
            let width = (bounds.width - dividers) / count
            for (index, view) in arrangedSubviews.enumerated() {
                view.frame = NSRect(
                    x: (width + dividerThickness) * CGFloat(index),
                    y: 0,
                    width: width,
                    height: bounds.height
                )
            }
        } else {
            let height = (bounds.height - dividers) / count
            for (index, view) in arrangedSubviews.enumerated() {
                view.frame = NSRect(
                    x: 0,
                    y: (height + dividerThickness) * CGFloat(index),
                    width: bounds.width,
                    height: height
                )
            }
        }
        adjustSubviews()
    }
}
