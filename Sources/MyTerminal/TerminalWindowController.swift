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
    /// 복원한 탭 중 아직 셸을 띄우지 않은 pane의 정보. 탭을 처음 열 때 꺼내
    /// 쓴다 — 탭 스무 개를 되살리면서 셸 스무 개를 한꺼번에 띄우지 않는다.
    private var dormantSessions: [UUID: WorkspaceState.Session] = [:]
    private let composer = CommandComposerView()
    /// pane마다 쓰다 만 글을 따로 들고 있다. 상자는 창에 하나뿐이라 포커스가
    /// 옮겨 갈 때 이 사전에서 꺼내 넣는다.
    private var drafts: [UUID: String] = [:]
    private var history = CommandHistory()
    /// Esc로 터미널로 나간 상태. 그때는 글자를 쳐도 상자로 돌리지 않는다 —
    /// vim처럼 화면 전체를 쓰는 도구를 쓰려고 나간 것이기 때문이다.
    private var typingRedirectSuspended = false
    /// 우리가 보낸 명령이 아직 끝나지 않았다. 그동안 키는 터미널로 간다.
    private var runningCommands: Set<UUID> = []

    init(fontSize: Float, theme: AppTheme, projects: [Project]) {
        self.fontSize = fontSize
        self.theme = theme
        self.projects = projects

        let window = TerminalHostWindow(
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
        window.interceptKeyDown = { [weak self] event in
            self?.redirectTypingToComposer(event) ?? false
        }
        wireComposer()
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

    // MARK: - 창 사이 이동

    /// 창을 옮겨 다니는 탭 묶음. 셸을 새로 띄우지 않고 세션 객체를 그대로
    /// 넘긴다 — 다시 만들면 스크롤백이 날아간다.
    struct DetachedTabs {
        let selection: SidebarSelection
        let tabs: [TerminalTab]
        let sessions: [UUID: TerminalSession]
    }

    func detachActiveTab() -> DetachedTabs? {
        guard var group = groups[activeSelection], let tab = group.activeTab else { return nil }
        let selection = activeSelection

        _ = group.closeTab(id: tab.id)
        groups[selection] = group.isEmpty ? nil : group

        let moved = extract(tab)
        removeTabView(tab.id)
        syncViews()
        closeIfEmpty()
        return DetachedTabs(selection: selection, tabs: [tab], sessions: moved)
    }

    func detachAllTabs() -> [DetachedTabs] {
        let detached = groups.map { selection, group in
            var moved: [UUID: TerminalSession] = [:]
            for tab in group.tabs {
                moved.merge(extract(tab)) { current, _ in current }
                removeTabView(tab.id)
            }
            return DetachedTabs(selection: selection, tabs: group.tabs, sessions: moved)
        }
        groups = [:]
        syncViews()
        closeIfEmpty()
        return detached
    }

    func adopt(_ detached: DetachedTabs) {
        for (id, session) in detached.sessions {
            session.delegate = self
            sessions[id] = session
        }
        var group = groups[detached.selection] ?? TabGroup()
        for tab in detached.tabs {
            group.append(tab)
        }
        groups[detached.selection] = group
        activeSelection = detached.selection

        sidebar.reload(projects: projects, selection: activeSelection)
        syncViews()
        focusActivePane()
    }

    /// 세션을 이 창에서 떼어 낸다.
    ///
    /// 뷰를 상위 뷰에서 먼저 빼는 것이 중요하다. `removeFromSuperview()`는
    /// 그 뷰를 가리키는 제약도 같이 걷어내므로, 새 창의 pane 컨테이너에 붙일
    /// 때 옛 컨테이너의 제약이 따라와 충돌하지 않는다.
    private func extract(_ tab: TerminalTab) -> [UUID: TerminalSession] {
        var moved: [UUID: TerminalSession] = [:]
        for id in tab.sessions {
            guard let session = sessions.removeValue(forKey: id) else { continue }
            session.setVisible(false)
            session.view.removeFromSuperview()
            moved[id] = session
        }
        return moved
    }

    /// 탭을 다 내보낸 창은 닫는다. 마지막 탭을 새 창으로 뺐는데 빈 창이
    /// 남아 있으면 안 된다.
    private func closeIfEmpty() {
        guard groups.values.allSatisfy(\.isEmpty) else { return }
        window?.close()
    }

    // MARK: - 입력 상자

    private func wireComposer() {
        // 셸이 쌓아 둔 히스토리를 밑에 깔아 둔다. 새 창에서도 ↑를 누르면
        // 어제 친 명령이 나온다.
        history.seed(ShellHistory.recent())
        composer.workingDirectory = { [weak self] in
            self?.activeSession?.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        composer.onSubmit = { [weak self] text in self?.submitFromComposer(text) }
        composer.onLeave = { [weak self] in self?.leaveComposer() }
        composer.onForwardKey = { [weak self] event in self?.forwardToTerminal(event) }
        composer.onHistoryStep = { [weak self] step in
            guard let self else { return nil }
            return history.step(step, current: composer.text)
        }
        composer.onTextChange = { [weak self] text in
            guard let self else { return }
            // 사용자가 직접 고쳤으면 되부르기를 놓는다. 그러지 않으면 다음 ↑가
            // 새로 친 글이 아니라 아까 훑던 자리에서 이어진다.
            history.endRecall()
            guard let id = groups[activeSelection]?.activeTab?.focus else { return }
            drafts[id] = text.isEmpty ? nil : text
            (NSApp.delegate as? AppDelegate)?.workspaceDidChange()
        }
    }

    /// 상자에 쓴 것을 셸로 보낸다. 붙여넣기로 넣고 Return을 따로 보낸다 —
    /// 여러 줄이 한 덩어리로 들어가야 첫 줄만 실행되는 일이 없다(bracketed
    /// paste). 바이트는 순서대로 흐르므로 사이에 기다릴 필요가 없다.
    private func submitFromComposer(_ text: String) {
        guard let session = activeSession else { return }
        if !text.isEmpty {
            session.view.sendText(text)
            history.record(text)
            runningCommands.insert(session.id)
        }
        sendReturn(to: session)
        drafts[session.id] = nil
        (NSApp.delegate as? AppDelegate)?.workspaceDidChange()
    }

    private func sendReturn(to session: TerminalSession) {
        guard
            let window,
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        else { return }
        session.view.keyDown(with: event)
    }

    /// Esc. 다음 타이핑이 상자로 끌려오지 않게 표시해 둔다.
    private func leaveComposer() {
        typingRedirectSuspended = true
        focusActivePane()
    }

    /// 상자를 켜거나 끈 뒤 화면을 다시 맞춘다.
    func reloadComposer() {
        syncViews()
        if !composerEnabled { focusActivePane() }
    }

    func focusComposer() {
        guard composerEnabled else { return }
        typingRedirectSuspended = false
        composer.focus()
    }

    private func forwardToTerminal(_ event: NSEvent) {
        guard let session = activeSession else { return }
        session.view.keyDown(with: event)
    }

    /// 터미널에 포커스가 있는데 사용자가 글자를 치기 시작하면 상자로 돌린다.
    ///
    /// 돌리지 않는 경우가 셋이다. 상자를 껐을 때, Esc로 터미널을 쓰겠다고
    /// 나갔을 때, 그리고 우리가 보낸 명령이 아직 돌고 있을 때다. 셋째가
    /// 중요하다 — 상자에서 `vim`을 띄웠으면 그다음 키는 vim이 받아야 한다.
    private func redirectTypingToComposer(_ event: NSEvent) -> Bool {
        guard composerEnabled, !typingRedirectSuspended else { return false }
        guard let session = activeSession else { return false }
        guard !runningCommands.contains(session.id) else { return false }
        guard window?.firstResponder === session.view else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control) else { return false }
        guard let characters = event.characters, let scalar = characters.unicodeScalars.first
        else { return false }
        // 방향키·기능키는 characters가 사용자 영역(0xF700~)으로 온다. Return과
        // Tab, Esc는 셸이 받아야 하므로 제어문자도 그대로 흘려보낸다.
        guard scalar.value < 0xF700, !CharacterSet.controlCharacters.contains(scalar) else {
            return false
        }

        composer.beginTyping(with: event)
        return true
    }

    private var composerEnabled: Bool {
        (NSApp.delegate as? AppDelegate)?.isComposerEnabled ?? true
    }

    /// 상자를 포커스한 pane 아래로 옮겨 붙이고, 그 pane의 쓰다 만 글을 넣는다.
    private func syncComposer(for group: TabGroup) {
        let focus = group.activeTab?.focus
        for (tabID, view) in tabViews {
            view.attachComposer(
                tabID == group.activeTabID && composerEnabled ? composer : nil,
                to: tabID == group.activeTabID ? focus : nil
            )
        }
        guard composerEnabled else { return }
        composer.apply(colors: theme.chrome(systemIsDark: windowIsDark))
        composer.applyFontSize(fontSize)

        let draft = focus.flatMap { drafts[$0] } ?? ""
        if composer.text != draft, !composer.isFocused {
            composer.text = draft
            history.endRecall()
        }
        if !composer.isFocused { composer.hideCompletions() }
    }

    func pasteFromClipboard() {
        // 상자가 있으면 붙여넣기는 상자로 간다. 여러 줄을 붙였을 때 바로
        // 실행되는 사고를 막고, 보고 고친 뒤 ⏎를 누를 수 있다.
        guard composerEnabled, let text = NSPasteboard.general.string(forType: .string) else {
            activeSession?.pasteFromClipboard()
            return
        }
        focusComposer()
        composer.text = composer.text.isEmpty ? text : composer.text + text
    }

    func clearScreen() {
        activeSession?.clearScreen()
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
        id: UUID = UUID(),
        workingDirectory: String? = nil,
        restorePath: String? = nil
    ) -> TerminalSession? {
        let session: TerminalSession
        switch selection {
        case .home:
            session = TerminalSession(
                id: id,
                workingDirectory: workingDirectory,
                environment: [:],
                fontSize: fontSize,
                theme: theme,
                restorePath: restorePath
            )
        case let .project(projectID):
            guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
            session = TerminalSession(
                id: id,
                workingDirectory: workingDirectory ?? project.directory,
                environment: [
                    "MYTERMINAL_PROJECT": project.name,
                    "MYTERMINAL_PROJECT_DIR": project.directory,
                ],
                fontSize: fontSize,
                theme: theme,
                restorePath: restorePath
            )
        }

        session.delegate = self
        sessions[session.id] = session
        return session
    }

    /// 복원한 탭을 처음 열 때 그 탭의 셸을 띄운다. 저장해 둔 아이디를 그대로
    /// 살려야 화면 스냅샷이 같은 pane으로 돌아간다.
    private func wakeSessions(for tab: TerminalTab, in selection: SidebarSelection) {
        for id in tab.sessions where sessions[id] == nil {
            let saved = dormantSessions.removeValue(forKey: id)
            _ = makeSession(
                for: selection,
                id: id,
                workingDirectory: saved?.workingDirectory,
                restorePath: (NSApp.delegate as? AppDelegate)?.snapshotPath(for: id)
            )
        }
    }

    /// 종료 직전에 살아 있는 pane의 화면을 뜬다. 아직 깨우지 않은 pane은
    /// 이번 실행에서 건드린 적이 없으므로 남겨 둔 기록이 그대로 다음 실행까지
    /// 간다.
    func captureSnapshots(into store: SessionSnapshotStore) {
        for session in sessions.values {
            guard let text = session.snapshot() else { continue }
            store.write(text, for: session.id)
        }
    }

    /// 이 창이 알고 있는 모든 pane. 남은 기록을 치울 때 기준이 된다.
    var knownSessionIDs: Set<UUID> {
        Set(sessions.keys).union(dormantSessions.keys)
    }

    /// 화면을 모델에 맞춘다. 탭·분할이 바뀔 때마다 여기 한 번만 들르면 된다.
    private func syncViews() {
        let group = groups[activeSelection] ?? TabGroup()
        let colors = theme.chrome(systemIsDark: windowIsDark)

        // 보이는 탭의 셸만 띄운다. 나머지는 배치만 들고 기다린다.
        if let active = group.activeTab {
            wakeSessions(for: active, in: activeSelection)
        }

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

        syncComposer(for: group)
        tabBar.reload(group)
        // 탭이 하나면 탭바를 감춘다 — 탭을 안 쓰는 사람에게는 그냥 터미널이다.
        tabBar.isHidden = group.tabs.count < 2
        window?.title = windowTitle(for: group)
        (NSApp.delegate as? AppDelegate)?.workspaceDidChange()
    }

    // MARK: - 배치 저장·복원

    func snapshotState() -> WorkspaceState.Window {
        let frame = window?.frame ?? .zero
        return WorkspaceState.Window(
            frame: WorkspaceState.Frame(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            ),
            activeSelection: activeSelection,
            groups: groups.map { WorkspaceState.Group(selection: $0.key, tabs: $0.value) },
            sessions: sessionStates(),
            composerHistory: history.entries
        )
    }

    /// 살아 있는 셸과 아직 안 깨운 pane을 함께 담는다. 안 깨운 쪽을 빼면
    /// 켜자마자 다시 끄는 것만으로 열어 두었던 탭이 사라진다.
    private func sessionStates() -> [WorkspaceState.Session] {
        let live = sessions.values.map {
            WorkspaceState.Session(
                id: $0.id,
                workingDirectory: $0.workingDirectory,
                title: $0.title,
                draft: drafts[$0.id]
            )
        }
        return live + dormantSessions.values.filter { sessions[$0.id] == nil }
    }

    /// 저장해 둔 창을 되살린다. 사라진 프로젝트의 탭은 버린다.
    func restore(_ state: WorkspaceState.Window) {
        let live = Set(projects.map(\.id))
        for group in state.groups {
            if case let .project(id) = group.selection, !live.contains(id) { continue }
            groups[group.selection] = group.tabs
        }
        for session in state.sessions {
            dormantSessions[session.id] = session
            if let draft = session.draft, !draft.isEmpty {
                drafts[session.id] = draft
            }
        }
        history = CommandHistory(entries: state.composerHistory ?? [])
        history.seed(ShellHistory.recent())

        activeSelection = groups[state.activeSelection] == nil ? .home : state.activeSelection
        let frame = NSRect(
            x: state.frame.x,
            y: state.frame.y,
            width: state.frame.width,
            height: state.frame.height
        )
        if frame.width > 200, frame.height > 200 {
            window?.setFrame(frame, display: false)
        }
        sidebar.reload(projects: projects, selection: activeSelection)
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
            drafts.removeValue(forKey: id)
            runningCommands.remove(id)
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

    func windowDidResize(_: Notification) {
        (NSApp.delegate as? AppDelegate)?.workspaceDidChange()
    }

    func windowDidMove(_: Notification) {
        (NSApp.delegate as? AppDelegate)?.workspaceDidChange()
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
        // pane을 클릭해 옮겨 갔으면 그 pane에서는 다시 상자로 끌어온다.
        typingRedirectSuspended = false
        guard let selection = selection(holding: session.id), selection == activeSelection else {
            return
        }
        guard var group = groups[selection], group.activeTab?.focus != session.id else { return }
        group.focus(session.id)
        groups[selection] = group
        syncViews()
    }

    func sessionDidFinishCommand(_ session: TerminalSession) {
        runningCommands.remove(session.id)
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
