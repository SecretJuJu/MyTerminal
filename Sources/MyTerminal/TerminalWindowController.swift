import AppKit
import GhosttyTerminal

/// One window = a project sidebar plus one live terminal session per project
/// the user has visited in this window.
///
/// Sessions are built on first visit and kept afterwards, so switching projects
/// preserves each shell and its scrollback. Only the active one draws; the rest
/// stay attached and occluded (see `TerminalSession.setVisible`).
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let sessionContainer = NSView()
    private let sidebar = ProjectSidebarViewController()

    private var sessions: [SidebarSelection: TerminalSession] = [:]
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
            viewController: SessionContainerViewController(container: sessionContainer)
        )
        sessionItem.minimumThickness = 420
        splitViewController.addSplitViewItem(sessionItem)

        window.contentViewController = splitViewController

        super.init(window: window)
        sidebar.delegate = self
        window.delegate = self
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

    /// 사이드바와 창 외관을 테마에 맞춘다.
    ///
    /// 밝기를 스스로 정하는 테마(Dracula 같은)에만 창 외관을 고정한다. 그래야
    /// 제목 표시줄과 버튼이 어두운 사이드바와 따로 놀지 않는다. 시스템을
    /// 따라가는 테마에 이걸 걸면 터미널까지 한쪽으로 묶여 자동 전환이 죽는다.
    private func applyChrome() {
        sidebar.apply(theme: theme)
        window?.appearance = theme.followsSystemAppearance
            ? nil
            : NSAppearance(named: theme.chrome(systemIsDark: true).isDark ? .darkAqua : .aqua)
    }

    func reloadProjects(_ projects: [Project]) {
        self.projects = projects

        let live = Set(projects.map { SidebarSelection.project($0.id) })
        for key in sessions.keys where key != .home && !live.contains(key) {
            discardSession(key)
        }
        if case .project = activeSelection, !live.contains(activeSelection) {
            activate(.home)
        }

        sidebar.reload(projects: projects, selection: activeSelection)
    }

    /// Used right after a project is created so the window that asked for it
    /// lands in the new project instead of staying on the home shell.
    func select(_ selection: SidebarSelection) {
        activate(selection)
        sidebar.reload(projects: projects, selection: activeSelection)
    }

    func pasteFromClipboard() {
        sessions[activeSelection]?.pasteFromClipboard()
    }

    func jumpToPrompt(by offset: Int16) {
        sessions[activeSelection]?.jumpToPrompt(by: offset)
    }

    // MARK: - Sessions

    private func activate(_ selection: SidebarSelection) {
        guard let session = session(for: selection) else {
            // The project went away between the click and here; fall back
            // rather than leaving the pane blank.
            if selection != .home { activate(.home) }
            return
        }

        if let current = sessions[activeSelection], current !== session {
            current.setVisible(false)
        }
        activeSelection = selection
        session.setVisible(true)
        window?.title = title(for: selection)
        session.focus()
    }

    private func session(for selection: SidebarSelection) -> TerminalSession? {
        if let existing = sessions[selection] { return existing }

        let session: TerminalSession
        switch selection {
        case .home:
            session = TerminalSession(
                workingDirectory: nil,
                environment: [:],
                fontSize: fontSize,
                theme: theme
            )
        case let .project(id):
            guard let project = projects.first(where: { $0.id == id }) else { return nil }
            session = TerminalSession(
                workingDirectory: project.directory,
                environment: [
                    "MYTERMINAL_PROJECT": project.name,
                    "MYTERMINAL_PROJECT_DIR": project.directory,
                ],
                fontSize: fontSize,
                theme: theme
            )
        }

        session.delegate = self
        sessions[selection] = session
        install(session)
        return session
    }

    private func install(_ session: TerminalSession) {
        let view = session.view
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        sessionContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: sessionContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: sessionContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: sessionContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: sessionContainer.bottomAnchor),
        ])
    }

    private func discardSession(_ selection: SidebarSelection) {
        guard let session = sessions.removeValue(forKey: selection) else { return }
        session.setVisible(false)
        session.view.removeFromSuperview()
    }

    private func title(for selection: SidebarSelection) -> String {
        switch selection {
        case .home:
            "MyTerminal"
        case let .project(id):
            projects.first { $0.id == id }?.name ?? "MyTerminal"
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_: Notification) {
        (NSApp.delegate as? AppDelegate)?.windowControllerDidClose(self)
    }
}

// MARK: - TerminalSessionDelegate

extension TerminalWindowController: TerminalSessionDelegate {
    func session(_ session: TerminalSession, didChangeTitle title: String) {
        guard sessions[activeSelection] === session else { return }
        window?.title = title
    }

    func sessionDidClose(_ session: TerminalSession) {
        guard let key = sessions.first(where: { $0.value === session })?.key else { return }
        discardSession(key)

        // Exiting the home shell closes the window, the way it did before
        // projects existed. Exiting a project's shell just drops that pane.
        guard key != .home else {
            window?.close()
            return
        }
        activate(.home)
        sidebar.reload(projects: projects, selection: activeSelection)
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

// MARK: - Session container

/// `NSSplitViewItem` needs a view controller; the window controller owns the
/// sessions that go inside, so this is nothing more than a holder for the view.
@MainActor
private final class SessionContainerViewController: NSViewController {
    private let container: NSView

    init(container: NSView) {
        self.container = container
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = container
    }
}
