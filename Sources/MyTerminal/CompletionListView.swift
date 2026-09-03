import AppKit

/// Tab을 눌렀을 때 상자 위로 뜨는 후보 목록.
///
/// 창이나 팝오버가 아니라 그냥 pane 안에 얹는 뷰다. 별도 창으로 띄우면 키
/// 포커스가 그쪽으로 옮겨 가 상자의 편집 상태가 흔들린다 — 목록은 보여 주기만
/// 하고 키는 계속 상자가 받아야 한다.
@MainActor
final class CompletionListView: NSView {
    private static let rowHeight: CGFloat = 20
    private static let maxVisibleRows = 8

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var candidates: [String] = []
    private var colors: ChromeColors = AppTheme.ghosttyDefault.chrome(systemIsDark: false)
    private var heightConstraint: NSLayoutConstraint?

    private(set) var selectedIndex = 0

    var selectedCandidate: String? {
        candidates.indices.contains(selectedIndex) ? candidates[selectedIndex] : nil
    }

    var isShowing: Bool { !isHidden && !candidates.isEmpty }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        isHidden = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.selectionHighlightStyle = .regular

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let height = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(colors: ChromeColors) {
        self.colors = colors
        layer?.backgroundColor = colors.background
            .blended(withFraction: colors.isDark ? 0.12 : 0.06, of: colors.foreground)?.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = colors.foreground.withAlphaComponent(0.18).cgColor
        tableView.reloadData()
    }

    func show(_ candidates: [String]) {
        self.candidates = candidates
        selectedIndex = 0
        isHidden = candidates.isEmpty
        let rows = min(candidates.count, Self.maxVisibleRows)
        heightConstraint?.constant = candidates.isEmpty
            ? 0
            : CGFloat(rows) * Self.rowHeight + 8
        tableView.reloadData()
        select(0)
    }

    func hide() {
        candidates = []
        isHidden = true
        heightConstraint?.constant = 0
    }

    /// 목록 안에서 위아래로 옮긴다. 끝에서는 반대편으로 돈다.
    func moveSelection(by offset: Int) {
        guard !candidates.isEmpty else { return }
        select((selectedIndex + offset + candidates.count) % candidates.count)
    }

    private func select(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        selectedIndex = index
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }
}

// MARK: - 목록

extension CompletionListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int {
        candidates.count
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: candidates[row])
        label.font = NSFont(name: FontPreferences.monoFamily(), size: 11)
            ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = colors.foreground
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        let row = CompletionRowView()
        row.selectionColor = colors.selection
        return row
    }

    /// 목록은 키를 가져가지 않는다. 선택은 상자가 방향키로 옮긴다.
    func selectionShouldChange(in _: NSTableView) -> Bool {
        true
    }
}

/// 선택 강조를 테마 색으로 그린다. 사이드바와 같은 이유로 기본 강조색을 쓰지
/// 않는다 — 시스템 강조색은 테마와 따로 논다.
private final class CompletionRowView: NSTableRowView {
    var selectionColor: NSColor = .selectedContentBackgroundColor

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in _: NSRect) {
        guard isSelected else { return }
        selectionColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 4, yRadius: 4).fill()
    }
}
