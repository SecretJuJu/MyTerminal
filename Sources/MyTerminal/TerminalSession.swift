import AppKit
import GhosttyTerminal

@MainActor
protocol TerminalSessionDelegate: AnyObject {
    func session(_ session: TerminalSession, didChangeTitle title: String)
    func sessionDidTakeFocus(_ session: TerminalSession)
    func sessionDidFinishCommand(_ session: TerminalSession)
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
        theme: AppTheme,
        restorePath: String? = nil
    ) {
        self.id = id
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory

        // 되찍을 내용이 있고 셸을 아는 경우에만 감싼다.
        let replay = restorePath.flatMap { path in
            LoginShell.current.map { (path: path, shell: $0) }
        }

        view = TerminalView(frame: .zero)
        controller = TerminalController(theme: theme.terminalTheme()) { builder in
            builder.withFontSize(fontSize)
            FontPreferences.apply(to: &builder)
            builder.withCursorStyleBlink(true)
            builder.withWindowPaddingX(8)
            builder.withWindowPaddingY(8)
            if let replay {
                // 명령을 바꾸면 ghostty가 셸 종류를 알아내지 못해 셸 통합이
                // 꺼진다. 어떤 셸인지 직접 알려 줘야 프롬프트 경계·pwd·종료
                // 코드가 계속 들어온다.
                builder.withCustom("shell-integration", replay.shell.integration)
            }
        }

        var options = TerminalSurfaceOptions()
        options.workingDirectory = workingDirectory
        // Tag child processes so external tools can correlate them back to
        // this pane (useful once blocks/sessions land).
        var env = environment.merging(["MYTERMINAL_PANE": id.uuidString]) { current, _ in
            current
        }
        if let replay {
            // 경로는 명령 문자열이 아니라 환경변수로 넘긴다. Application
            // Support 경로에는 공백이 있어서 명령에 박으면 단어가 갈린다.
            env["MYTERMINAL_RESTORE"] = replay.path
            env["MYTERMINAL_SHELL"] = replay.shell.path
            options.command =
                #"/bin/sh -c 'cat "$MYTERMINAL_RESTORE" 2>/dev/null; exec "$MYTERMINAL_SHELL" -l'"#
        }
        options.envVars = env
        view.configuration = options
        view.controller = controller
        view.delegate = self
    }

    /// 화면에 떠 있는 글자를 평문으로 뜬다.
    ///
    /// 클립보드를 거치는 것은 취향이 아니라 유일한 길이다. libghostty의 텍스트
    /// 읽기 API는 패키지 밖으로 열려 있지 않고, 클립보드 쓰기 콜백도 곧장
    /// `NSPasteboard.general`로 쓰기 때문에 가로챌 자리가 없다. 그래서 앞뒤로
    /// 클립보드를 보관했다 되돌린다 — 종료 직전에 복사해 둔 것을 이 기능이
    /// 훔쳐 가면 안 된다.
    func snapshot() -> String? {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []

        defer {
            pasteboard.clearContents()
            if !saved.isEmpty {
                pasteboard.writeObjects(saved as [any NSPasteboardWriting])
            }
        }

        guard view.performBindingAction("select_all"), view.copySelectedTextToPasteboard() else {
            return nil
        }
        return pasteboard.string(forType: .string)
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

    func clearScreen() {
        view.performBindingAction("clear_screen")
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
        // 상자가 이걸 기다린다. 우리가 보낸 명령이 끝났다는 뜻이라, 여기서
        // 다시 타이핑을 상자로 끌어온다.
        delegate?.sessionDidFinishCommand(self)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        workingDirectory = path
        Log.info("pwd → \(path)")
    }
}
