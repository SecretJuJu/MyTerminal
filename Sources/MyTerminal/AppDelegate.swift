import AppKit
import GhosttyTerminal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let defaultFontSize: Float = 13
    private static let minFontSize: Float = 9
    private static let maxFontSize: Float = 28

    private var windows: [TerminalWindowController] = []
    private var fontSize: Float = AppDelegate.defaultFontSize
    private var theme: AppTheme = .ghosttyDefault
    private var themeSubmenu: NSMenu?
    /// 탭 자리를 고르는 ⌘1…⌘9 항목 수.
    private static let tabShortcutCount = 9

    private let projectStore = ProjectStore()
    /// A sheet is owned by nobody else while it is up; without this it would
    /// be released the moment the presenting call returns.
    private var activeSheet: FormSheet?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_: Notification) {
        Log.info("launched — building menu and opening first window")
        NSApp.mainMenu = buildMainMenu()
        newWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    // MARK: - Window management

    @objc func newWindow(_: Any?) {
        let controller = TerminalWindowController(
            fontSize: fontSize,
            theme: theme,
            projects: projectStore.projects
        )
        windows.append(controller)
        controller.showWindow(nil)
    }

    func windowControllerDidClose(_ controller: TerminalWindowController) {
        windows.removeAll { $0 === controller }
    }

    // MARK: - Actions

    @objc private func zoomFontIn(_: Any?) {
        setFontSize(min(fontSize + 1, AppDelegate.maxFontSize))
    }

    @objc private func zoomFontOut(_: Any?) {
        setFontSize(max(fontSize - 1, AppDelegate.minFontSize))
    }

    @objc private func resetFontSize(_: Any?) {
        setFontSize(AppDelegate.defaultFontSize)
    }

    @objc private func pasteIntoTerminal(_: Any?) {
        keyWindowController()?.pasteFromClipboard()
    }

    @objc private func jumpToPreviousPrompt(_: Any?) {
        keyWindowController()?.jumpToPrompt(by: -1)
    }

    @objc private func jumpToNextPrompt(_: Any?) {
        keyWindowController()?.jumpToPrompt(by: 1)
    }

    @objc private func newProject(_: Any?) {
        guard let controller = keyWindowController() else { return }
        presentNewProjectSheet(from: controller)
    }

    @objc private func addRepository(_: Any?) {
        guard let controller = keyWindowController() else { return }
        guard let projectID = controller.activeProjectID else {
            presentAlert(
                title: "프로젝트를 먼저 고르세요",
                message: "왼쪽 목록에서 저장소를 넣을 프로젝트를 고른 뒤 다시 시도하세요.",
                over: controller.window
            )
            return
        }
        presentAddRepositorySheet(projectID: projectID, from: controller)
    }

    @objc private func newTab(_: Any?) {
        keyWindowController()?.openTab()
    }

    /// ⌘W. 나뉘어 있으면 pane 하나만, 하나뿐이면 탭째 닫는다. 창은 ⇧⌘W.
    @objc private func closeTab(_: Any?) {
        keyWindowController()?.closeActive()
    }

    @objc private func selectNextTab(_: Any?) {
        keyWindowController()?.selectNextTab()
    }

    @objc private func selectPreviousTab(_: Any?) {
        keyWindowController()?.selectPreviousTab()
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? Int else { return }
        keyWindowController()?.selectTab(number: number)
    }

    @objc private func splitRight(_: Any?) {
        keyWindowController()?.splitActivePane(axis: .horizontal)
    }

    @objc private func splitDown(_: Any?) {
        keyWindowController()?.splitActivePane(axis: .vertical)
    }

    @objc private func focusPaneLeft(_: Any?) {
        keyWindowController()?.movePaneFocus(.left)
    }

    @objc private func focusPaneRight(_: Any?) {
        keyWindowController()?.movePaneFocus(.right)
    }

    @objc private func focusPaneUp(_: Any?) {
        keyWindowController()?.movePaneFocus(.up)
    }

    @objc private func focusPaneDown(_: Any?) {
        keyWindowController()?.movePaneFocus(.down)
    }

    @objc private func removeCurrentProject(_: Any?) {
        guard let controller = keyWindowController() else { return }
        guard let projectID = controller.activeProjectID else {
            presentAlert(
                title: "프로젝트를 먼저 고르세요",
                message: "왼쪽 목록에서 제거할 프로젝트를 고른 뒤 다시 시도하세요.",
                over: controller.window
            )
            return
        }
        removeProject(id: projectID, from: controller)
    }

    // MARK: - Menu

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = menu("MyTerminal", items: [
            ("About MyTerminal", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), nil),
            separator,
            ("Quit MyTerminal", #selector(NSApplication.terminate(_:)), "q"),
        ])
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = menu("File", items: [
            ("New Tab", #selector(newTab(_:)), "t"),
            ("New Window", #selector(newWindow(_:)), "n"),
            separator,
            // Uppercase key equivalents carry Shift, so these read ⇧⌘N / ⇧⌘A.
            ("New Project…", #selector(newProject(_:)), "N"),
            ("Add Repository…", #selector(addRepository(_:)), "A"),
            ("Remove Project…", #selector(removeCurrentProject(_:)), nil),
            separator,
            ("Close Tab", #selector(closeTab(_:)), "w"),
            ("Close Window", #selector(NSWindow.performClose(_:)), "W"),
        ])
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = menu("Edit", items: [
            // `copy:` travels the responder chain to the focused terminal view.
            ("Copy", NSSelectorFromString("copy:"), "c"),
            ("Paste", #selector(pasteIntoTerminal(_:)), "v"),
        ])
        mainMenu.addItem(editMenuItem)

        let themeMenuItem = NSMenuItem()
        themeMenuItem.submenu = buildThemeMenu()
        themeSubmenu = themeMenuItem.submenu
        mainMenu.addItem(themeMenuItem)

        let viewMenu = menu("View", items: [
            // `toggleSidebar:` is NSSplitViewController's; the responder chain
            // carries it from the key window down to the split controller.
            ("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s"),
            separator,
            ("Split Right", #selector(splitRight(_:)), "d"),
            ("Split Down", #selector(splitDown(_:)), "D"),
            ("Select Pane Left", #selector(focusPaneLeft(_:)), "←"),
            ("Select Pane Right", #selector(focusPaneRight(_:)), "→"),
            ("Select Pane Up", #selector(focusPaneUp(_:)), "↑"),
            ("Select Pane Down", #selector(focusPaneDown(_:)), "↓"),
            separator,
            ("Bigger Font", #selector(zoomFontIn(_:)), "+"),
            ("Smaller Font", #selector(zoomFontOut(_:)), "-"),
            ("Reset Font Size", #selector(resetFontSize(_:)), "0"),
            separator,
            ("Previous Prompt", #selector(jumpToPreviousPrompt(_:)), "↑"),
            ("Next Prompt", #selector(jumpToNextPrompt(_:)), "↓"),
        ])
        // ⌘S alone would read as Save in a terminal; ⌃⌘S is the sidebar toggle
        // people already have in their fingers from Xcode.
        viewMenu.item(withTitle: "Toggle Sidebar")?
            .keyEquivalentModifierMask = [.control, .command]
        // pane 이동은 ⌘⌥+방향키. 방향키에 ⌘만 얹으면 프롬프트 이동과 부딪친다.
        for title in [
            "Select Pane Left", "Select Pane Right", "Select Pane Up", "Select Pane Down",
        ] {
            viewMenu.item(withTitle: title)?
                .keyEquivalentModifierMask = [.command, .option]
        }
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = buildWindowMenu()
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }

    /// 탭 이동은 macOS 관례대로 Window 메뉴에 둔다. ⌃⇥는 Tab 문자에 Control을
    /// 얹어야 나오므로 튜플로는 표현할 수 없어 뒤에서 손본다.
    private func buildWindowMenu() -> NSMenu {
        let windowMenu = menu("Window", items: [
            ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            separator,
            ("Show Next Tab", #selector(selectNextTab(_:)), "\t"),
            ("Show Previous Tab", #selector(selectPreviousTab(_:)), "\t"),
            separator,
        ])
        windowMenu.item(withTitle: "Show Next Tab")?
            .keyEquivalentModifierMask = [.control]
        windowMenu.item(withTitle: "Show Previous Tab")?
            .keyEquivalentModifierMask = [.control, .shift]

        for number in 1 ... Self.tabShortcutCount {
            let item = NSMenuItem(
                title: "탭 \(number)",
                action: #selector(selectTabByNumber(_:)),
                keyEquivalent: "\(number)"
            )
            // 숫자를 실어 보내야 하므로 responder chain에 태우지 않고 직접 받는다.
            item.target = self
            item.representedObject = number
            windowMenu.addItem(item)
        }
        return windowMenu
    }

    // MARK: - Helpers

    private func setFontSize(_ size: Float) {
        guard size != fontSize else { return }
        fontSize = size
        for controller in windows {
            controller.applyFontSize(size)
        }
    }

    // MARK: - Theme

    private func buildThemeMenu() -> NSMenu {
        let submenu = NSMenu(title: "Theme")
        for candidate in AppTheme.allCases {
            let item = NSMenuItem(
                title: candidate.displayName,
                action: #selector(selectTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = candidate
            item.state = candidate == theme ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let candidate = sender.representedObject as? AppTheme else { return }
        setTheme(candidate)
    }

    private func setTheme(_ newTheme: AppTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        for controller in windows {
            controller.applyTheme(newTheme)
        }
        for item in themeSubmenu?.items ?? [] {
            if let candidate = item.representedObject as? AppTheme {
                item.state = candidate == theme ? .on : .off
            }
        }
        Log.info("theme → \(newTheme.displayName)")
    }

    private func keyWindowController() -> TerminalWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.first
    }

    private func menu(
        _ title: String,
        items: [(String, Selector?, String?)]
    ) -> NSMenu {
        let submenu = NSMenu(title: title)
        for item in items {
            if item.0.isEmpty {
                submenu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(
                title: item.0,
                action: item.1,
                keyEquivalent: item.2 ?? ""
            )
            // nil target = responder chain (first responder first), so the
            // focused terminal view handles its own copy: etc.
            menuItem.target = nil
            submenu.addItem(menuItem)
        }
        return submenu
    }

    private var separator: (String, Selector?, String?) { ("", nil, nil) }
}

// MARK: - Projects
//
// Projects follow the same one-way flow as font size and theme: the store is
// mutated here, then the whole list is pushed out to every window. Windows and
// sidebars never write back — they only ask.

extension AppDelegate {
    func presentNewProjectSheet(from controller: TerminalWindowController) {
        guard let window = controller.window else { return }
        let sheet = NewProjectSheet()
        sheet.onSubmit = { [weak self, weak controller] name, parent in
            guard let self, let controller else { return "창이 닫혔습니다." }
            return createProject(name: name, parent: parent, from: controller)
        }
        present(sheet, over: window)
    }

    func presentAddRepositorySheet(projectID: UUID, from controller: TerminalWindowController) {
        guard let window = controller.window else { return }
        guard let project = projectStore.project(id: projectID) else { return }

        let sheet = AddRepositorySheet(project: project)
        sheet.onSubmit = { [weak self] path in
            guard let self else { return "앱이 종료되는 중입니다." }
            return await addRepository(path: path, to: projectID)
        }
        present(sheet, over: window)
    }

    func removeProject(id: UUID, from controller: TerminalWindowController) {
        guard let project = projectStore.project(id: id), let window = controller.window else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "‘\(project.name)’을(를) 제거할까요?"
        alert.informativeText = project.repositories.isEmpty
            ? "\(project.directory)"
            : """
            worktree \(project.repositories.count)개를 정리합니다. 커밋하지 않은 변경이 남은 worktree는 지우지 않고 남겨 둡니다. 원본 저장소와 브랜치는 그대로입니다.
            \(project.directory)
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                Task { await self.purge(project, over: window) }
            }
        }
    }

    /// worktree를 먼저 걷어내고, 다 걷어낸 경우에만 프로젝트를 목록에서 뺀다.
    /// 하나라도 남으면 그 저장소만 프로젝트에 남겨 둔다 — 이미 지운 worktree의
    /// 기록을 그대로 들고 있으면 목록이 디스크와 어긋난다.
    private func purge(_ project: Project, over window: NSWindow) async {
        var blocked: [ProjectRepository] = []
        var reasons: [String] = []

        for repository in project.repositories {
            do {
                try await Git.removeWorktree(
                    repository: repository.sourcePath,
                    destination: repository.worktreePath
                )
                Log.info("worktree removed — \(repository.worktreePath)")
            } catch {
                blocked.append(repository)
                reasons.append("• \(repository.name): \(error.localizedDescription)")
            }
        }

        guard blocked.isEmpty else {
            var partial = project
            partial.repositories = blocked
            try? projectStore.update(partial)
            projectsDidChange()
            presentBlockedRemoval(partial, reasons: reasons, over: window)
            return
        }

        try? projectStore.remove(id: project.id)
        // 세션을 먼저 정리한다. 셸이 살아 있는 디렉터리를 지우면 그 셸의
        // 작업 디렉터리가 허공을 가리킨 채로 남는다.
        projectsDidChange()
        ProjectStore.discardDirectoryIfOnlyMarkerRemains(at: project.directory)
    }

    private func presentBlockedRemoval(
        _ project: Project,
        reasons: [String],
        over window: NSWindow
    ) {
        let alert = NSAlert()
        alert.messageText = "정리하지 못한 worktree가 있습니다"
        alert.informativeText = """
        \(reasons.joined(separator: "\n"))

        남은 worktree를 그대로 두고 프로젝트만 목록에서 뺄 수 있습니다. 나중에 원본 저장소에서 `git worktree prune`으로 정리하면 됩니다.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "목록에서만 빼기")
        alert.addButton(withTitle: "그대로 두기")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                try? self.projectStore.remove(id: project.id)
                self.projectsDidChange()
            }
        }
    }

    func removeRepository(
        _ repository: ProjectRepository,
        from projectID: UUID,
        in controller: TerminalWindowController
    ) {
        guard let window = controller.window else { return }

        let alert = NSAlert()
        alert.messageText = "‘\(repository.name)’ worktree를 제거할까요?"
        alert.informativeText = """
        \(repository.worktreePath)
        원본 저장소와 \(repository.branch) 브랜치는 남습니다. 커밋하지 않은 변경이 있으면 git이 제거를 거부합니다.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "제거")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                Task { await self.detachRepository(repository, from: projectID, over: window) }
            }
        }
    }

    private func createProject(
        name: String,
        parent: URL,
        from controller: TerminalWindowController
    ) -> String? {
        do {
            let project = try projectStore.create(name: name, parent: parent)
            projectsDidChange()
            controller.select(.project(project.id))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func addRepository(path: String, to projectID: UUID) async -> String? {
        guard var project = projectStore.project(id: projectID) else {
            return "프로젝트를 찾을 수 없습니다."
        }

        do {
            let root = try await Git.repositoryRoot(at: path)
            let commonDirectory = try await Git.commonDirectory(at: root)
            guard !project.repositories.contains(where: {
                $0.commonDirectory == commonDirectory
            }) else {
                return "이미 이 프로젝트에 들어 있는 저장소입니다."
            }

            let destination = ProjectStore.availableWorktreePath(
                named: (root as NSString).lastPathComponent,
                in: project.directory
            )
            try await Git.addWorktree(
                repository: root,
                destination: destination,
                branch: project.branchName
            )

            project.repositories.append(ProjectRepository(
                sourcePath: root,
                worktreePath: destination,
                branch: project.branchName,
                commonDirectory: commonDirectory
            ))
            try projectStore.update(project)
            projectsDidChange()
            Log.info("worktree added — \(destination) on \(project.branchName)")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func detachRepository(
        _ repository: ProjectRepository,
        from projectID: UUID,
        over window: NSWindow
    ) async {
        do {
            try await Git.removeWorktree(
                repository: repository.sourcePath,
                destination: repository.worktreePath
            )
            guard var project = projectStore.project(id: projectID) else { return }
            project.repositories.removeAll { $0.id == repository.id }
            try projectStore.update(project)
            projectsDidChange()
            Log.info("worktree removed — \(repository.worktreePath)")
        } catch {
            presentAlert(
                title: "worktree를 제거하지 못했습니다",
                message: error.localizedDescription,
                over: window
            )
        }
    }

    private func projectsDidChange() {
        for controller in windows {
            controller.reloadProjects(projectStore.projects)
        }
    }

    private func present(_ sheet: FormSheet, over window: NSWindow) {
        activeSheet = sheet
        sheet.onDismiss = { [weak self, weak sheet] in
            guard self?.activeSheet === sheet else { return }
            self?.activeSheet = nil
        }
        sheet.present(over: window)
    }

    private func presentAlert(title: String, message: String, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        guard let window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window) { _ in }
    }
}
