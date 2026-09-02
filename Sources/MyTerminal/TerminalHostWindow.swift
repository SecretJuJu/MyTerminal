import AppKit

/// 창이 키를 먼저 본다.
///
/// 입력 상자가 있는데도 터미널에 포커스가 있을 때 사용자가 글자를 치기
/// 시작하면, 그 키를 상자로 돌린다. `NSWindow.sendEvent`에서 가로채는 이유는
/// 여기가 responder chain보다 앞이기 때문이다 — 터미널 뷰가 키를 먹은 뒤에는
/// 되돌릴 자리가 없고, 첫 글자를 놓치면 한글 조합이 깨진다.
@MainActor
final class TerminalHostWindow: NSWindow {
    /// true를 돌려주면 그 키를 창이 처리한 것으로 보고 더 내려보내지 않는다.
    var interceptKeyDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, interceptKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}
