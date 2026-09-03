import Foundation

/// Tab 자동완성.
///
/// 셸에게 물어볼 수가 없어서 우리가 만든다. 상자에 쓴 글은 셸의 줄 버퍼에
/// 들어 있지 않으므로 Tab을 셸로 넘겨 봐야 완성할 것이 없고, 완성 결과를
/// 화면에서 긁어오는 방법은 프롬프트 모양에 기댄다.
///
/// 그래서 대신 파일 경로와 명령 이름을 직접 찾는다. Tab을 누르는 경우의
/// 대부분이 이 둘이다. git 브랜치 이름처럼 셸 플러그인이 아는 완성은 여기서
/// 못 한다 — 그건 esc로 터미널에 나가서 치면 된다.
enum CommandCompletion {
    struct Result: Equatable {
        /// 바꿔 넣을 자리(현재 토큰)의 UTF-16 범위.
        let range: NSRange
        /// 후보들. 각각이 토큰을 통째로 대신한다.
        let candidates: [String]
        /// 후보들이 공통으로 가진 앞부분. 여기까지는 바로 채워도 된다.
        let commonPrefix: String
    }

    /// 디렉터리 내용을 돌려주는 자리. 테스트가 진짜 디스크를 안 건드리게 뺐다.
    @MainActor
    struct Sources {
        var listDirectory: (String) -> [(name: String, isDirectory: Bool)]
        var executables: () -> [String]

        static let system = Sources(
            listDirectory: { path in
                let manager = FileManager.default
                guard let names = try? manager.contentsOfDirectory(atPath: path) else { return [] }
                return names.map { name in
                    var isDirectory: ObjCBool = false
                    let full = (path as NSString).appendingPathComponent(name)
                    manager.fileExists(atPath: full, isDirectory: &isDirectory)
                    return (name, isDirectory.boolValue)
                }
            },
            executables: { ExecutableIndex.shared.names() }
        )
    }

    /// 커서 앞의 토큰을 보고 후보를 만든다. 후보가 없으면 nil.
    @MainActor
    static func complete(
        text: String,
        caret: Int,
        workingDirectory: String,
        home: String = NSHomeDirectory(),
        sources: Sources = .system
    ) -> Result? {
        let utf16 = Array(text.utf16)
        let caret = min(max(caret, 0), utf16.count)
        let start = tokenStart(in: utf16, before: caret)
        let token = String(decoding: utf16[start ..< caret], as: UTF16.self)
        let range = NSRange(location: start, length: caret - start)

        let candidates = isCommandPosition(in: utf16, tokenStart: start)
            ? commandCandidates(for: token, sources: sources)
            : pathCandidates(
                for: token,
                workingDirectory: workingDirectory,
                home: home,
                sources: sources
            )

        guard !candidates.isEmpty else { return nil }
        return Result(
            range: range,
            candidates: candidates,
            commonPrefix: longestCommonPrefix(of: candidates)
        )
    }

    /// 토큰이 시작하는 자리. 공백에서 끊되 역슬래시로 이스케이프한 공백은 잇는다.
    static func tokenStart(in utf16: [UInt16], before caret: Int) -> Int {
        var index = caret
        while index > 0 {
            let character = utf16[index - 1]
            let isBreak = character == 0x20 || character == 0x09 // space, tab
                || character == 0x0A // newline
                || character == 0x3B || character == 0x7C || character == 0x26 // ; | &
            guard isBreak else {
                index -= 1
                continue
            }
            // 이스케이프한 공백은 토큰의 일부다.
            if character == 0x20, index >= 2, utf16[index - 2] == 0x5C {
                index -= 2
                continue
            }
            break
        }
        return index
    }

    /// 이 토큰이 명령 이름 자리인지. 앞에 다른 토큰이 없으면(파이프·세미콜론
    /// 바로 뒤 포함) 명령 자리다.
    static func isCommandPosition(in utf16: [UInt16], tokenStart: Int) -> Bool {
        var index = tokenStart - 1
        while index >= 0 {
            let character = utf16[index]
            if character == 0x20 || character == 0x09 {
                index -= 1
                continue
            }
            // ; | & 뒤는 새 명령의 시작이다.
            return character == 0x3B || character == 0x7C || character == 0x26 || character == 0x0A
        }
        return true
    }

    // MARK: - 후보

    @MainActor
    private static func commandCandidates(for token: String, sources: Sources) -> [String] {
        // 경로 모양으로 쓰기 시작했으면 명령 이름이 아니라 파일을 찾는 중이다.
        guard !token.contains("/"), !token.hasPrefix("~") else { return [] }
        guard !token.isEmpty else { return [] }
        return sources.executables()
            .filter { $0.hasPrefix(token) }
            .sorted()
    }

    @MainActor
    private static func pathCandidates(
        for token: String,
        workingDirectory: String,
        home: String,
        sources: Sources
    ) -> [String] {
        let (directoryToken, prefix) = split(token)
        let searchPath = resolve(
            directoryToken,
            workingDirectory: workingDirectory,
            home: home
        )

        return sources.listDirectory(searchPath)
            .filter { entry in
                // 숨김 파일은 사용자가 점을 찍었을 때만 보여 준다.
                guard entry.name.hasPrefix(prefix) else { return false }
                return prefix.hasPrefix(".") || !entry.name.hasPrefix(".")
            }
            .map { entry in
                let name = entry.isDirectory ? entry.name + "/" : entry.name
                return directoryToken + escape(name)
            }
            .sorted()
    }

    /// 토큰을 디렉터리 부분과 찾을 이름으로 가른다. `src/Ter` → (`src/`, `Ter`).
    static func split(_ token: String) -> (directory: String, prefix: String) {
        guard let slash = token.lastIndex(of: "/") else { return ("", token) }
        let after = token.index(after: slash)
        return (String(token[..<after]), String(token[after...]))
    }

    private static func resolve(
        _ directoryToken: String,
        workingDirectory: String,
        home: String
    ) -> String {
        if directoryToken.isEmpty { return workingDirectory }
        if directoryToken == "~/" { return home }
        if directoryToken.hasPrefix("~/") {
            return (home as NSString)
                .appendingPathComponent(String(directoryToken.dropFirst(2)))
        }
        if directoryToken.hasPrefix("/") { return directoryToken }
        return (workingDirectory as NSString).appendingPathComponent(directoryToken)
    }

    /// 공백이 든 이름은 셸이 한 낱말로 읽도록 역슬래시를 붙인다.
    static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "\\ ")
    }

    static func longestCommonPrefix(of candidates: [String]) -> String {
        guard var prefix = candidates.first else { return "" }
        for candidate in candidates.dropFirst() {
            while !candidate.hasPrefix(prefix), !prefix.isEmpty {
                prefix.removeLast()
            }
            if prefix.isEmpty { break }
        }
        return prefix
    }
}

// MARK: - 실행 파일 목록

/// `PATH`에 있는 실행 파일 이름. 한 번 훑어 두고 재사용한다 — Tab을 누를
/// 때마다 디렉터리 수십 개를 읽으면 눌린 뒤에야 목록이 뜬다.
@MainActor
final class ExecutableIndex {
    static let shared = ExecutableIndex()

    private var cached: [String]?

    func names() -> [String] {
        if let cached { return cached }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)

        var names: Set<String> = []
        let manager = FileManager.default
        for path in paths {
            guard let entries = try? manager.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries where manager.isExecutableFile(
                atPath: (path as NSString).appendingPathComponent(entry)
            ) {
                names.insert(entry)
            }
        }
        let sorted = names.sorted()
        cached = sorted
        return sorted
    }
}
