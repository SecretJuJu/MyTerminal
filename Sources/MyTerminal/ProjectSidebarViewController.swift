import AppKit

/// 사이드바에서 고를 수 있는 대상. `home`은 프로젝트에 속하지 않은
/// 기본 셸이다 — 프로젝트를 하나도 안 만든 사람에게는 이게 앱의 전부다.
enum SidebarSelection: Hashable, Codable {
    case home
    case project(UUID)
}

@MainActor
protocol ProjectSidebarDelegate: AnyObject {
    func sidebar(_ sidebar: ProjectSidebarViewController, didSelect selection: SidebarSelection)
    func sidebarDidRequestNewProject(_ sidebar: ProjectSidebarViewController)
    func sidebar(
        _ sidebar: ProjectSidebarViewController,
        didRequestAddRepositoryTo projectID: UUID
    )
    func sidebar(
        _ sidebar: ProjectSidebarViewController,
        didRequestRemoveProject projectID: UUID
    )
    func sidebar(
        _ sidebar: ProjectSidebarViewController,
        didRequestRemove repository: ProjectRepository,
        from projectID: UUID
    )
}

/// 왼쪽 프로젝트 목록. 프로젝트 아래에 그 프로젝트가 들고 있는 worktree가
/// 붙는다. 아래쪽 버튼 두 개로 프로젝트와 저장소를 추가한다.
@MainActor
final class ProjectSidebarViewController: NSViewController {
    weak var delegate: (any ProjectSidebarDelegate)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let newProjectButton = NSButton(title: "프로젝트 추가", target: nil, action: nil)
    private let addRepositoryButton = NSButton(title: "레포 추가", target: nil, action: nil)

    private var nodes: [Node] = []
    private var selection: SidebarSelection = .home
    private var theme: AppTheme = .ghosttyDefault
    private var colors: ChromeColors = AppTheme.ghosttyDefault.chrome(systemIsDark: false)
    /// 저장소가 처음 생긴 순간에만 펼친다. 갓 만든 프로젝트는 비어 있어서
    /// 그때 펼쳐 봐야 아무 일도 일어나지 않고, 그걸 펼친 것으로 쳐 버리면
    /// 정작 저장소를 넣었을 때 접힌 채로 남는다. 한 번 펼친 뒤의 펼침·접힘은
    /// `Node`가 아이디로 같음을 판단하므로 `reloadData()`를 지나도 유지된다.
    private var expandedOnce: Set<UUID> = []
    /// 프로그램이 고른 선택은 델리게이트로 되돌리지 않는다. 창이 알려 준
    /// 선택을 다시 창에게 통보하면 그대로 왕복한다.
    private var isRestoringSelection = false

    override func loadView() {
        let root = BackgroundView(frame: NSRect(x: 0, y: 0, width: 240, height: 480))
        root.onAppearanceChange = { [weak self] in self?.refreshColors() }
        view = root

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 14
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = contextMenu()
        outlineView.doubleAction = #selector(revealClickedItem(_:))
        outlineView.target = self

        // 목록은 투명하게 두고 배경은 루트 뷰가 칠한다. 테마 색은 한 군데서만
        // 바르는 편이 선택 강조와 어긋날 일이 없다.
        outlineView.backgroundColor = .clear
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        for button in [newProjectButton, addRepositoryButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        newProjectButton.action = #selector(addProject(_:))
        addRepositoryButton.action = #selector(addRepository(_:))

        let buttons = NSStackView(views: [newProjectButton, addRepositoryButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - 테마

    /// 해석한 색이 아니라 테마 자체를 받는다. 시스템 라이트/다크를 따라가는
    /// 테마는 외관이 바뀔 때마다 색이 달라지는데, 그걸 창에서 감시하는 것보다
    /// 여기서 다시 계산하는 편이 짧다.
    func apply(theme: AppTheme) {
        self.theme = theme
        refreshColors()
    }

    private func refreshColors() {
        let isDark = view.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        colors = theme.chrome(systemIsDark: isDark)

        view.wantsLayer = true
        view.layer?.backgroundColor = colors.background.cgColor
        outlineView.reloadData()
        restoreSelection()
    }

    // MARK: - 갱신

    func reload(projects: [Project], selection: SidebarSelection) {
        self.selection = selection
        nodes = [Node(content: .home)] + projects.map(Node.init(project:))
        outlineView.reloadData()

        for node in nodes where !node.children.isEmpty {
            guard case let .project(project) = node.content else { continue }
            guard expandedOnce.insert(project.id).inserted else { continue }
            outlineView.expandItem(node)
        }

        restoreSelection()
        updateButtons()
    }

    private func restoreSelection() {
        let target = nodes.firstIndex { $0.selection == selection }
        isRestoringSelection = true
        defer { isRestoringSelection = false }

        guard let target else {
            outlineView.deselectAll(nil)
            return
        }
        let row = outlineView.row(forItem: nodes[target])
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func updateButtons() {
        addRepositoryButton.isEnabled = selectedProjectID != nil
    }

    private var selectedProjectID: UUID? {
        guard case let .project(id) = selection else { return nil }
        return id
    }

    // MARK: - 동작

    @objc private func addProject(_: Any?) {
        delegate?.sidebarDidRequestNewProject(self)
    }

    @objc private func addRepository(_: Any?) {
        guard let selectedProjectID else { return }
        delegate?.sidebar(self, didRequestAddRepositoryTo: selectedProjectID)
    }

    @objc private func revealClickedItem(_: Any?) {
        guard let node = clickedNode(), let path = node.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func removeClickedItem(_: Any?) {
        guard let node = clickedNode() else { return }
        switch node.content {
        case .home:
            break
        case let .project(project):
            delegate?.sidebar(self, didRequestRemoveProject: project.id)
        case let .repository(repository, projectID):
            delegate?.sidebar(self, didRequestRemove: repository, from: projectID)
        }
    }

    private func clickedNode() -> Node? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? Node
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }
}

// MARK: - NSOutlineViewDataSource

extension ProjectSidebarViewController: NSOutlineViewDataSource {
    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return nodes.count }
        return node.children.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return nodes[index] }
        return node.children[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.children.isEmpty
    }
}

// MARK: - NSOutlineViewDelegate

extension ProjectSidebarViewController: NSOutlineViewDelegate {
    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor _: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? Node else { return nil }

        let cell = outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: self)
            as? NSTableCellView ?? Self.makeCell()
        cell.textField?.stringValue = node.title
        cell.textField?.toolTip = node.path
        cell.textField?.textColor = colors.foreground
        cell.imageView?.image = NSImage(
            systemSymbolName: node.symbolName,
            accessibilityDescription: nil
        )
        cell.imageView?.contentTintColor = colors.foreground.withAlphaComponent(0.65)
        return cell
    }

    func outlineView(_: NSOutlineView, rowViewForItem _: Any) -> NSTableRowView? {
        let row = ThemedRowView()
        row.selectionColor = colors.selection
        return row
    }

    func outlineViewSelectionDidChange(_: Notification) {
        guard !isRestoringSelection else { return }
        guard
            outlineView.selectedRow >= 0,
            let node = outlineView.item(atRow: outlineView.selectedRow) as? Node
        else { return }

        selection = node.selection
        updateButtons()
        delegate?.sidebar(self, didSelect: node.selection)
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("projectCell")

    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellIdentifier

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        cell.addSubview(icon)
        cell.imageView = icon

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(label)
        cell.textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - NSMenuDelegate

extension ProjectSidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode(), node.path != nil else { return }

        menu.addItem(
            withTitle: "Finder에서 보기",
            action: #selector(revealClickedItem(_:)),
            keyEquivalent: ""
        )
        switch node.content {
        case .home:
            break
        case .project:
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "프로젝트 제거…",
                action: #selector(removeClickedItem(_:)),
                keyEquivalent: ""
            )
        case .repository:
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "worktree 제거…",
                action: #selector(removeClickedItem(_:)),
                keyEquivalent: ""
            )
        }
        for item in menu.items { item.target = self }
    }
}

// MARK: - 테마를 따르는 조각들

/// 시스템 외관이 바뀌면 알려 주는 배경 뷰. 라이트/다크를 따라가는 테마는
/// 그때 색이 달라지므로 다시 칠해야 한다.
private final class BackgroundView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// 선택 강조를 테마의 선택 색으로 그린다.
///
/// `interiorBackgroundStyle`을 `.normal`로 묶어 두는 것이 핵심이다. 기본값은
/// 선택된 행을 `.emphasized`로 보고 글자를 흰색으로 바꿔 버리는데, Alabaster의
/// 선택 색(#C9D0D9)처럼 밝은 테마에서는 흰 글자가 읽히지 않는다. 색은 셀에서
/// 직접 정한다.
private final class ThemedRowView: NSTableRowView {
    var selectionColor: NSColor = .selectedContentBackgroundColor

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in _: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        selectionColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 5, dy: 1),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }
}

// MARK: - Node

/// `NSOutlineView`는 항목을 `isEqual:`로 식별한다. 구조체를 그대로 넘기면
/// 새로 만들 때마다 다른 항목으로 보여 펼침 상태가 매번 풀리므로, 아이디로
/// 같음을 판단하는 객체로 감싼다.
private final class Node: NSObject {
    enum Content {
        case home
        case project(Project)
        case repository(ProjectRepository, projectID: UUID)
    }

    let content: Content
    let children: [Node]

    init(content: Content, children: [Node] = []) {
        self.content = content
        self.children = children
    }

    convenience init(project: Project) {
        self.init(
            content: .project(project),
            children: project.repositories.map {
                Node(content: .repository($0, projectID: project.id))
            }
        )
    }

    var identifier: String {
        switch content {
        case .home: "home"
        case let .project(project): "project:\(project.id)"
        case let .repository(repository, _): "repository:\(repository.id)"
        }
    }

    var title: String {
        switch content {
        case .home: "홈"
        case let .project(project): project.name
        case let .repository(repository, _): repository.name
        }
    }

    var symbolName: String {
        switch content {
        case .home: "house"
        case .project: "folder"
        case .repository: "arrow.triangle.branch"
        }
    }

    var path: String? {
        switch content {
        case .home: nil
        case let .project(project): project.directory
        case let .repository(repository, _): repository.worktreePath
        }
    }

    /// 저장소 행을 고르면 그 저장소가 속한 프로젝트로 넘어간다. 터미널은
    /// 프로젝트 단위로 열리므로 worktree 하나만 따로 열 자리는 없다.
    var selection: SidebarSelection {
        switch content {
        case .home: .home
        case let .project(project): .project(project.id)
        case let .repository(_, projectID): .project(projectID)
        }
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? Node)?.identifier == identifier
    }

    override var hash: Int {
        identifier.hashValue
    }
}
