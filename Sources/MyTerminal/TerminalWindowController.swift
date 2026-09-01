import AppKit
import GhosttyTerminal

/// One window = a project sidebar, a tab bar, and one live terminal session per
/// pane the user has opened in this window.
///
/// 탭은 사이드바 선택에 속한다. 프로젝트를 바꾸면 탭 묶음이 통째로 교체되고,
/// 떠난 프로젝트의 셸은 그대로 남아 기다린다. 세션은 첫 방문에 만들어 두고
/// 계속 붙여 둔다 — 활성 pane만 그리고 나머지는 occluded로 두는데, occluded
/// surface도 tick은 돌기 때문에 제목·pwd·종료 이벤트가 계속 흐른다
/// (`TerminalSession.setVisible`).
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let sessionContainer = NSView()
    private let tabBar = TabBarView()
    private let sidebar = ProjectSidebarViewController()

    private var groups: [SidebarSelection: TabGroup] = [:]
    private var sessions: [UUID: TerminalSession] = [:]
    /// 탭 하나당 화면 하나. 탭을 바꿀 때 감추기만 하므로 셸과 스크롤백이 남는다.
    private var tabViews: [UUID: SplitLayoutView] = [:]
    private var activeSelection: SidebarSelection = .home
    private var projects: [Project] = []
    private var fontSize: Float
    private var theme: AppTheme

    init(fontSize: Float, theme: AppTheme, projects: [Project]) {
        self.fontSize = fontSize
        self.theme = theme
        self.projects = projects

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MyTerminal"
        window.contentMinSize = NSSize(width: 720, height: 320)
        window.isRestorable = false

        let splitViewController = NSSplitViewController()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        splitViewController.addSplitViewItem(sidebarItem)

        let sessionItem = NSSplitViewItem(
            viewController: SessionAreaViewController(
                tabBar: tabBar,
                container: sessionContainer
            )
        )
        sessionItem.minimumThickness = 420
        splitViewController.addSplitViewItem(sessionItem)

        window.contentViewController = splitViewController

        super.init(window: window)
        sidebar.delegate = self
        window.delegate = self
        tabBar.onSelect = { [weak self] tabID in self?.selectTab(id: tabID) }
        tabBar.onClose = { [weak self] tabID in self?.closeTab(id: tabID, in: nil) }
        tabBar.onNew = { [weak self] in self?.openTab() }
        applyChrome()
        sidebar.reload(projects: projects, selection: activeSelection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        activate(activeSelection)
    }

    /// The project the sidebar is currently pointed at, if any. `AppDelegate`
    /// reads it so the "Add Repository…" menu item knows what to target.
    var activeProjectID: UUID? {
        guard case let .project(id) = activeSelection else { return nil }
        return id
    }

    // MARK: - Fan-out from AppDelegate

    func applyFontSize(_ size: Float) {
        guard size != fontSize else { return }
        fontSize = size
        for session in sessions.values {
            session.applyFontSize(size)
        }
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        let terminalTheme = theme.terminalTheme()
        for session in sessions.values {
            session.applyTheme(terminalTheme)
        }
        applyChrome()
    }

    /// 사이드바·탭바·창 외관을 테마에 맞춘다.
    ///
    /// 밝기를 스스로 정하는 테마(Dracula 같은)에만 창 외관을 고정한다. 그래야
    /// 제목 표시줄과 버튼이 어두운 사이드바와 따로 놀지 않는다. 시스템을
    /// 따라가는 테마에 이걸 걸면 터미널까지 한쪽으로 묶여 자동 전환이 죽는다.
    private func applyChrome() {
        sidebar.apply(theme: theme)
        tabBar.apply(theme: theme)
        let colors = theme.chrome(systemIsDark: windowIsDark)
        for view in tabViews.values {
            view.apply(colors: colors)
        }
        window?.appearance = theme.followsSystemAppearance
            ? nil
            : NSAppearance(named: theme.chrome(systemIsDark: true).isDark ? .darkAqua : .aqua)
    }

    private var windowIsDark: Bool {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func reloadProjects(_ projects: [Project]) {
        self.projects = projects

        let live = Set(projects.map { SidebarSelection.project($0.id) })
        for (selection, group) in groups where selection != .home && !live.contains(selection) {
            discard(group)
            groups[selection] = nil
        }
        if case .project = activeSelection, !live.contains(activeSelection) {
            activate(.home)
        }

        sidebar.reload(projects: projects, selection: activeSelection)
        syncViews()
    }

    /// Used right after a project is created so the window that asked for it
    /// lands in the new project instead of staying on the home shell.
    func select(_ selection: SidebarSelection) {
        activate(selection)
        sidebar.reload(projects: projects, selection: activeSelection)
    }

    // MARK: - Commands from the menu

    func openTab() {
        guard let session = makeSession(for: activeSelection) else { return }
        var group = groups[activeSelection] ?? TabGroup()
        group.append(TerminalTab(session: session.id, title: session.title))
        groups[activeSelection] = group
        syncViews()
        focusActivePane()
    }

    /// ⌘W. 나뉘어 있으면 pane 하나만, 하나뿐이면 탭째 닫는다.
    func closeActive() {
        guard let tab = groups[activeSelection]?.activeTab else { return }
        if tab.sessions.count > 1 {
            closePane(tab.focus, in: activeSelection)
        } else {
            closeTab(id: tab.id, in: activeSelection)
        }
    }

    func selectNextTab() {
        guard var group = groups[activeSelection] else { return }
        group.activateNext()
        groups[activeSelection] = group
        syncViews()
        focusActivePane()
    }

    func selectPreviousTab() {
        guard var group = groups[activeSelection] else { return }
        group.activatePrevious()
        groups[activeSelection] = group
        syncViews()
        focusActivePane()
    }

    /// 1-based. 그 자리에 탭이 없으면 아무 일도 하지 않는다.
    func selectTab(number: Int) {
        guard var group = groups[activeSelection] else { return }
        group.activate(index: number - 1)
        groups[activeSelection] = group
        syncViews()
        focusActivePane()
    }

    /// 활성 pane을 나눠 새 셸을 띄운다. 새 pane은 나눈 pane이 마지막으로
    /// 알려 준 작업 디렉터리에서 시작한다 — 같은 자리에서 명령 하나를 더
    /// 돌리려고 나누는 것이 대부분이다.
    func splitActivePane(axis: SplitTree<UUID>.Axis) {
        guard var group = groups[activeSelection], let tab = group.activeTab else { return }
        let origin = sessions[tab.focus]?.workingDirectory
        guard let session = makeSession(for: activeSelection, workingDirectory: origin) else {
            return
        }
        group.split(tab: tab.id, newSession: session.id, axis: axis)
        groups[activeSelection] = group
        syncViews()
        focusActivePane()
    }

    func movePaneFocus(_ direction: SplitTree<UUID>.Direction) {
        guard var group = groups[activeSelection], let tab = group.activeTab else { return }
        guard let next = tab.layout.neighbor(of: tab.focus, direction: direction) else { return }
        group.focus(next)
        groups[activeSelection] = group
        syncViews()
        focusActivePane()
    }

    func pasteFromClipboard() {
        activeSession?.pasteFromClipboard()
    }

    func jumpToPrompt(by offset: Int16) {
        activeSession?.jumpToPrompt(by: offset)
    }

    // MARK: - Sessions

    private var activeSession: TerminalSession? {
        guard let focus = groups[activeSelection]?.activeTab?.focus else { return nil }
        return sessions[focus]
    }

    private func activate(_ selection: SidebarSelection) {
        guard ensureTab(for: selection) else {
            // The project went away between the click and here; fall back
            // rather than leaving the pane blank.
            if selection != .home { activate(.home) }
            return
        }
        activeSelection = selection
        syncViews()
        focusActivePane()
    }

    /// 선택에 탭이 하나도 없으면 만든다. 프로젝트가 사라졌으면 false.
    private func ensureTab(for selection: SidebarSelection) -> Bool {
        if let group = groups[selection], !group.isEmpty { return true }
        guard let session = makeSession(for: selection) else { return false }
        var group = TabGroup()
        group.append(TerminalTab(session: session.id, title: session.title))
        groups[selection] = group
        return true
    }

    private func makeSession(
        for selection: SidebarSelection,
        workingDirectory: String? = nil
    ) -> TerminalSession? {
        let session: TerminalSession
        switch selection {
        case .home:
            session = TerminalSession(
                workingDirectory: workingDirectory,
                environment: [:],
                fontSize: fontSize,
                theme: theme
            )
        case let .project(id):
            guard let project = projects.first(where: { $0.id == id }) else { return nil }
            session = TerminalSession(
                workingDirectory: workingDirectory ?? project.directory,
                environment: [
                    "MYTERMINAL_PROJECT": project.name,
                    "MYTERMINAL_PROJECT_DIR": project.directory,
                ],
                fontSize: fontSize,
                theme: theme
            )
        }

        session.delegate = self
        sessions[session.id] = session
        return session
    }

    /// 화면을 모델에 맞춘다. 탭·분할이 바뀔 때마다 여기 한 번만 들르면 된다.
    private func syncViews() {
        let group = groups[activeSelection] ?? TabGroup()
        let colors = theme.chrome(systemIsDark: windowIsDark)

        for tab in group.tabs {
            let view = tabView(for: tab.id)
            view.apply(colors: colors)
            view.apply(layout: tab.layout, sessions: sessions, focused: tab.focus)
            view.isHidden = tab.id != group.activeTabID
        }

        // 다른 프로젝트의 탭 화면은 붙어 있되 감춘다.
        let visibleTabs = Set(group.tabs.map(\.id))
        for (tabID, view) in tabViews where !visibleTabs.contains(tabID) {
            view.isHidden = true
        }

        let drawing = Set(group.activeTab?.sessions ?? [])
        for (id, session) in sessions {
            session.setVisible(drawing.contains(id))
        }

        tabBar.reload(group)
        // 탭이 하나면 탭바를 감춘다 — 탭을 안 쓰는 사람에게는 그냥 터미널이다.
        tabBar.isHidden = group.tabs.count < 2
        window?.title = windowTitle(for: group)
    }

    private func tabView(for tabID: UUID) -> SplitLayoutView {
        if let existing = tabViews[tabID] { return existing }

        let view = SplitLayoutView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        sessionContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: sessionContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: sessionContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: sessionContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: sessionContainer.bottomAnchor),
        ])
        tabViews[tabID] = view
        return view
    }

    private func focusActivePane() {
        activeSession?.focus()
    }

    // MARK: - 닫기

    /// `selection`이 nil이면 활성 선택에서 찾는다 — 탭바가 부를 때가 그렇다.
    private func closeTab(id: UUID, in selection: SidebarSelection?) {
        let selection = selection ?? activeSelection
        guard var group = groups[selection] else { return }
        let removed = group.closeTab(id: id)
        groups[selection] = group

        discard(sessionIDs: removed)
        removeTabView(id)
        finishClose(in: selection)
    }

    private func closePane(_ sessionID: UUID, in selection: SidebarSelection) {
        guard var group = groups[selection] else { return }
        let result = group.closePane(sessionID)
        groups[selection] = group

        discard(sessionIDs: result.removedSessions)
        if let removedTab = result.removedTab {
            removeTabView(removedTab)
        }
        finishClose(in: selection)
    }

    /// 탭이 다 닫힌 뒤의 처리.
    ///
    /// 홈의 마지막 탭을 닫으면 창을 닫는다 — 프로젝트가 생기기 전 이 앱이
    /// 그랬던 대로다. 프로젝트 탭을 다 닫으면 그 프로젝트만 비우고 홈으로
    /// 물러난다.
    private func finishClose(in selection: SidebarSelection) {
        if groups[selection]?.isEmpty == true {
            groups[selection] = nil
        }
        guard groups[selection] == nil, selection == activeSelection else {
            syncViews()
            focusActivePane()
            return
        }
        guard selection != .home else {
            window?.close()
            return
        }
        activate(.home)
        sidebar.reload(projects: projects, selection: activeSelection)
    }

    private func discard(_ group: TabGroup) {
        discard(sessionIDs: group.sessions)
        for tab in group.tabs {
            removeTabView(tab.id)
        }
    }

    private func discard(sessionIDs: [UUID]) {
        for id in sessionIDs {
            sessions.removeValue(forKey: id)?.setVisible(false)
        }
    }

    private func removeTabView(_ tabID: UUID) {
        tabViews.removeValue(forKey: tabID)?.removeFromSuperview()
    }

    // MARK: - 제목

    private func windowTitle(for group: TabGroup) -> String {
        guard let focus = group.activeTab?.focus, let session = sessions[focus] else {
            return baseTitle(for: activeSelection)
        }
        return session.title
    }

    private func baseTitle(for selection: SidebarSelection) -> String {
        switch selection {
        case .home:
            "MyTerminal"
        case let .project(id):
            projects.first { $0.id == id }?.name ?? "MyTerminal"
        }
    }

    private func selection(holding sessionID: UUID) -> SidebarSelection? {
        groups.first { $0.value.sessions.contains(sessionID) }?.key
    }

    private func selectTab(id: UUID) {
        guard var group = groups[activeSelection] else { return }
        group.activeTabID = id
        groups[activeSelection] = group
        syncViews()
        focusActivePane()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_: Notification) {
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
    }
}

// MARK: - TerminalSessionDelegate

extension TerminalWindowController: TerminalSessionDelegate {
    func session(_ session: TerminalSession, didChangeTitle title: String) {
        guard let selection = selection(holding: session.id) else { return }
        guard var group = groups[selection], let tab = group.tab(containing: session.id) else {
            return
        }
        // 탭 이름은 그 탭에서 포커스를 가진 pane이 정한다. 나뉜 탭에서 뒤쪽
        // pane의 제목까지 탭 이름을 바꾸면 이름이 계속 튄다.
        guard tab.focus == session.id else { return }

        group.rename(tab: tab.id, title: title)
        groups[selection] = group

        if selection == activeSelection, group.activeTabID == tab.id {
            window?.title = title
        }
        if selection == activeSelection {
            tabBar.reload(group)
        }
    }

    /// 클릭으로 pane을 옮겨 다닌 것을 모델에 반영한다. 이미 활성인 pane이면
    /// 아무 일도 하지 않는다 — 포커스 이벤트는 창을 다시 누를 때도 오므로
    /// 매번 화면을 다시 맞추면 헛일이 잦다.
    func sessionDidTakeFocus(_ session: TerminalSession) {
        guard let selection = selection(holding: session.id), selection == activeSelection else {
            return
        }
        guard var group = groups[selection], group.activeTab?.focus != session.id else { return }
        group.focus(session.id)
        groups[selection] = group
        syncViews()
    }

    func sessionDidClose(_ session: TerminalSession) {
        guard let selection = selection(holding: session.id) else { return }
        closePane(session.id, in: selection)
    }
}

// MARK: - ProjectSidebarDelegate

extension TerminalWindowController: ProjectSidebarDelegate {
    func sidebar(_: ProjectSidebarViewController, didSelect selection: SidebarSelection) {
        activate(selection)
    }

    func sidebarDidRequestNewProject(_: ProjectSidebarViewController) {
        (NSApp.delegate as? AppDelegate)?.presentNewProjectSheet(from: self)
    }

    func sidebar(
        _: ProjectSidebarViewController,
        didRequestAddRepositoryTo projectID: UUID
    ) {
        (NSApp.delegate as? AppDelegate)?
            .presentAddRepositorySheet(projectID: projectID, from: self)
    }

    func sidebar(
        _: ProjectSidebarViewController,
        didRequestRemoveProject projectID: UUID
    ) {
        (NSApp.delegate as? AppDelegate)?.removeProject(id: projectID, from: self)
    }

    func sidebar(
        _: ProjectSidebarViewController,
        didRequestRemove repository: ProjectRepository,
        from projectID: UUID
    ) {
        (NSApp.delegate as? AppDelegate)?
            .removeRepository(repository, from: projectID, in: self)
    }
}

// MARK: - Session area

/// `NSSplitViewItem` needs a view controller; the window controller owns the
/// tab bar and the sessions that go inside, so this only stacks them.
@MainActor
private final class SessionAreaViewController: NSViewController {
    private let tabBar: TabBarView
    private let container: NSView

    init(tabBar: TabBarView, container: NSView) {
        self.tabBar = tabBar
        self.container = container
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)
        root.addSubview(container)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}
