import Foundation

/// 셸이 쌓아 둔 명령 기록.
///
/// 입력 상자는 셸의 줄 편집을 대신하므로 ↑를 눌렀을 때 셸 히스토리가 나와야
/// 한다. 셸에게 물어볼 방법은 없다 — 프롬프트에 키를 보내 받아 오는 방식은
/// 화면을 긁어야 하고 프롬프트 모양에 기댄다. 그래서 히스토리 파일을 직접
/// 읽는다.
///
/// 읽기만 하고 우리 쪽에 저장하지 않는다. `workspace.json`에 남는 것은 이
/// 상자로 보낸 명령뿐이다 — 사용자의 히스토리를 우리 파일에 복제하면 토큰
/// 같은 것이 한 벌 더 생긴다.
enum ShellHistory {
    /// 되부르기에 쓸 최근 명령. 오래된 것이 앞, 최근이 뒤.
    static func recent(limit: Int = 3000) -> [String] {
        guard let url = fileURL() else { return [] }
        guard let data = try? Data(contentsOf: url) else {
            Log.info("shell history: \(url.lastPathComponent)를 읽지 못했다")
            return []
        }

        let commands = parse(data, kind: kind(for: url))
        Log.info("shell history: \(commands.count)개 읽음 (\(url.lastPathComponent))")
        return Array(commands.suffix(limit))
    }

    enum Kind {
        /// `: <시각>:<걸린 시간>;<명령>` 형식. 줄 끝 역슬래시로 이어진다.
        case zsh
        /// 한 줄에 명령 하나.
        case plain
        /// `- cmd: <명령>` 줄만 골라 쓴다.
        case fish
    }

    /// 파싱만 떼어 둔 자리. 파일 없이 검증한다.
    static func parse(_ data: Data, kind: Kind) -> [String] {
        let text = decode(data)
        switch kind {
        case .zsh:
            return dedupe(parseZsh(text))
        case .plain:
            return dedupe(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        case .fish:
            return dedupe(parseFish(text))
        }
    }

    // MARK: - 파일 찾기

    private static func fileURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["HISTFILE"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates: [URL]
        switch LoginShell.current?.integration {
        case "bash":
            candidates = [home.appendingPathComponent(".bash_history")]
        case "fish":
            candidates = [
                home.appendingPathComponent(".local/share/fish/fish_history"),
            ]
        default:
            candidates = [home.appendingPathComponent(".zsh_history")]
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func kind(for url: URL) -> Kind {
        switch url.lastPathComponent {
        case ".bash_history": .plain
        case "fish_history": .fish
        default: .zsh
        }
    }

    // MARK: - 읽기

    /// zsh는 아스키가 아닌 바이트를 메타 인코딩으로 적는다: `0x83` 다음 바이트를
    /// 32와 xor한 값이 원래 바이트다. 그대로 UTF-8로 읽으면 한글이 깨진다.
    static func decode(_ data: Data) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count)

        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0x83, data.index(after: index) < data.endIndex {
                bytes.append(data[data.index(after: index)] ^ 32)
                index = data.index(index, offsetBy: 2)
                continue
            }
            bytes.append(byte)
            index = data.index(after: index)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseZsh(_ text: String) -> [String] {
        var commands: [String] = []
        var pending: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if var current = pending {
                // 앞줄이 역슬래시로 끝났으면 이 줄은 그 명령의 다음 줄이다.
                current += "\n" + raw
                if raw.hasSuffix("\\") {
                    pending = String(current.dropLast())
                } else {
                    pending = nil
                    commands.append(current)
                }
                continue
            }

            let command = stripZshMetadata(raw)
            guard !command.isEmpty else { continue }
            if command.hasSuffix("\\") {
                pending = String(command.dropLast())
            } else {
                commands.append(command)
            }
        }

        if let leftover = pending, !leftover.isEmpty {
            commands.append(leftover)
        }
        return commands
    }

    /// `: 1788397245:0;cd ~/workspace` → `cd ~/workspace`.
    /// 확장 포맷을 쓰지 않는 설정도 있어서 형식이 아니면 줄 전체가 명령이다.
    private static func stripZshMetadata(_ line: String) -> String {
        guard line.hasPrefix(": ") else { return line }
        guard let separator = line.firstIndex(of: ";") else { return line }
        return String(line[line.index(after: separator)...])
    }

    private static func parseFish(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: "- cmd: ") else { return nil }
            return String(line[range.upperBound...])
        }
    }

    /// 잇달아 같은 명령만 접는다. 멀리 떨어진 중복은 그대로 둔다 — 되부를 때
    /// 최근 순서가 흐트러지지 않는 편이 손에 익다.
    private static func dedupe(_ commands: [String]) -> [String] {
        var result: [String] = []
        for command in commands {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, result.last != command else { continue }
            result.append(command)
        }
        return result
    }
}
