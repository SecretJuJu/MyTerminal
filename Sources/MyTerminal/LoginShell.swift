import Foundation

/// 사용자의 로그인 셸.
///
/// 화면 내용을 되찍으려면 셸을 우리가 만든 명령으로 감싸야 하는데, 그러면
/// ghostty가 명령 이름으로 셸 종류를 알아내는 자동 감지가 걸리지 않는다.
/// 그래서 어떤 셸인지 여기서 정해 설정으로 직접 알려 준다. 모르는 셸이면
/// 감싸지 않는다 — 복원을 포기하는 편이 셸을 망가뜨리는 것보다 낫다.
struct LoginShell: Hashable, Sendable {
    let path: String
    /// ghostty의 `shell-integration` 값. zsh/bash/fish만 지원한다.
    let integration: String

    static var current: LoginShell? {
        resolve(path: ProcessInfo.processInfo.environment["SHELL"] ?? passwdShell())
    }

    /// 지원하는 셸이면 값을 만든다. 경로가 비었거나 처음 보는 셸이면 nil.
    static func resolve(path: String?) -> LoginShell? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        guard ["zsh", "bash", "fish"].contains(name) else { return nil }
        return LoginShell(path: path, integration: name)
    }

    /// `SHELL`이 없는 환경(launchd로 바로 뜬 경우 등)을 위한 대비책.
    private static func passwdShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else {
            return nil
        }
        return String(cString: shell)
    }
}
