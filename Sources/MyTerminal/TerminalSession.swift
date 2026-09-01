import AppKit
import GhosttyTerminal

@MainActor
protocol TerminalSessionDelegate: AnyObject {
    func session(_ session: TerminalSession, didChangeTitle title: String)
    func sessionDidTakeFocus(_ session: TerminalSession)
    func sessionDidClose(_ session: TerminalSession)
}

/// 셸이 처음 뜰 때 쓸 이름. 탭 제목은 셸이 알려 주기 전까지 이걸 쓴다.
let defaultSessionTitle = "셸"

/// One Ghostty surface running a real shell (`backend: .exec` — libghostty owns
/// the PTY, spawns the user's login shell, and injects Ghostty shell
/// integration / terminfo from the package-bundled resources).
///
/// Each session builds its own `TerminalController`. The controller exposes
/// `onWakeup` / `shouldProcessWakeup` as single slots, not lists, so two
/// surfaces sharing one controller would fight over them: the later surface
/// overwrites the earlier one's wakeup and the earlier pane stops draining
/// ghostty's mailbox — no repaints, no title updates, and eventually a blocked
/// write thread.
@MainActor
final class TerminalSession {
    /// 창이 세션을 아이디로 들고 다닌다 — 탭·분할 모델은 세션 객체가 아니라
    /// 이 아이디만 알고, 배치를 저장할 때도 이 값이 실린다.
    let id: UUID
    let view: TerminalView
    weak var delegate: (any TerminalSessionDelegate)?

    /// 셸이 마지막으로 알려 준 제목. 탭바가 읽는다.
    private(set) var title = defaultSessionTitle
    /// 셸이 마지막으로 알려 준 작업 디렉터리. pane을 나눌 때 새 셸을 같은
    /// 자리에서 띄우는 데 쓴다.
    private(set) var workingDirectory: String?

    private let controller: TerminalController
    private var fontSize: Float

    init(
        id: UUID = UUID(),
        workingDirectory: String?,
        environment: [String: String],
        fontSize: Float,
        theme: AppTheme
    ) {
        self.id = id
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory

        view = TerminalView(frame: .zero)
        controller = TerminalController(theme: theme.terminalTheme()) { builder in
            builder.withFontSize(fontSize)
            FontPreferences.apply(to: &builder)
            builder.withCursorStyleBlink(true)
            builder.withWindowPaddingX(8)
            builder.withWindowPaddingY(8)
        }

        var options = TerminalSurfaceOptions()
        options.workingDirectory = workingDirectory
        // Tag child processes so external tools can correlate them back to
        // this pane (useful once blocks/sessions land).
        options.envVars = environment.merging(["MYTERMINAL_PANE": id.uuidString]) { current, _ in
            current
        }
        view.configuration = options
        view.controller = controller
        view.delegate = self
    }

    // MARK: - Fan-out from the window controller

    func applyFontSize(_ size: Float) {
        guard size != fontSize else { return }
        fontSize = size
        controller.setTerminalConfiguration(
            controller.terminalConfiguration.fontSize(size)
        )
    }

    func applyTheme(_ theme: TerminalTheme) {
        controller.setTheme(theme)
    }

    func pasteFromClipboard() {
        view.performBindingAction("paste_from_clipboard")
    }

    func jumpToPrompt(by offset: Int16) {
        view.jumpToPrompt(by: offset)
    }

    func focus() {
        view.acquireProgrammaticFocus()
    }

    /// Hidden sessions keep their shell and scrollback; they just stop drawing.
    /// Ghostty still ticks an occluded surface, which is what keeps titles, pwd
    /// and child-exit events flowing while the pane is off screen.
    func setVisible(_ visible: Bool) {
        view.isHidden = !visible
        view.setSurfaceVisible(visible)
    }
}

// MARK: - Terminal surface events
//
// These delegate callbacks are the raw material for the roadmap features
// (blocks, AI context, session history): Ghostty shell integration reports
// prompt/command boundaries, working directory, and command exit metadata.

extension TerminalSession:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceLifecycleDelegate
{
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        Log.info("surface attached — exec backend, shell spawning (\(surface))")
    }

    func terminalDidDetachSurface() {
        Log.info("surface detached")
    }

    func terminalDidChangeTitle(_ title: String) {
        self.title = title
        delegate?.session(self, didChangeTitle: title)
    }

    /// 클릭으로 pane을 옮겨 다니면 여기로 온다. 포커스를 잃는 쪽은 알리지
    /// 않는다 — 창이 키를 잃을 때도 같은 값이 오므로, 그걸로 활성 pane을
    /// 지우면 창을 다시 눌렀을 때 어느 pane이 활성이었는지 잊는다.
    func terminalDidChangeFocus(_ focused: Bool) {
        guard focused else { return }
        delegate?.sessionDidTakeFocus(self)
    }

    func terminalDidClose(processAlive: Bool) {
        Log.info("surface closed (processAlive=\(processAlive))")
        delegate?.sessionDidClose(self)
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        let millis = durationNanos / 1_000_000
        Log.info("command finished exit=\(exitCode.map(String.init) ?? "nil") duration=\(millis)ms")
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        workingDirectory = path
        Log.info("pwd → \(path)")
    }
}
