import AppKit
import GhosttyTerminal

@MainActor
protocol TerminalSessionDelegate: AnyObject {
    func session(_ session: TerminalSession, didChangeTitle title: String)
    func sessionDidClose(_ session: TerminalSession)
}

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
    let view: TerminalView
    weak var delegate: (any TerminalSessionDelegate)?

    private let controller: TerminalController
    private var fontSize: Float

    init(
        workingDirectory: String?,
        environment: [String: String],
        fontSize: Float,
        theme: AppTheme
    ) {
        self.fontSize = fontSize

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
        options.envVars = environment.merging(["MYTERMINAL_PANE": UUID().uuidString]) { current, _ in
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
    TerminalSurfaceLifecycleDelegate
{
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        Log.info("surface attached — exec backend, shell spawning (\(surface))")
    }

    func terminalDidDetachSurface() {
        Log.info("surface detached")
    }

    func terminalDidChangeTitle(_ title: String) {
        delegate?.session(self, didChangeTitle: title)
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
        Log.info("pwd → \(path)")
    }
}
