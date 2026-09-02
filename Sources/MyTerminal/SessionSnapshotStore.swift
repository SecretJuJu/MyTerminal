import Foundation

/// pane에 떠 있던 글자를 파일로 남겨 두는 자리.
///
/// 앱을 껐다 켜면 셸은 새로 뜨지만 화면은 그대로 있는 것처럼 보이게 하는 것이
/// 목적이다. 셸 프로세스를 살려 두지는 못한다 — 우리가 PTY를 갖고 있지 않고,
/// 셸을 `script(1)`로 감싸 출력을 계속 기록하는 방법은 창 크기 변경이 안쪽
/// 셸까지 가지 않아 쓸 수 없었다.
@MainActor
final class SessionSnapshotStore {
    /// 되찍을 분량. 화면 몇 장이면 충분하고, 그보다 길면 다시 켰을 때
    /// 스크롤이 옛날 것으로 가득 찬다.
    private static let maxLines = 2000
    private static let maxBytes = 256 * 1024

    /// 복원한 내용과 새 셸의 출력을 눈으로 가를 수 있게 넣는 줄.
    private static let marker = "\u{1B}[2m──────── 이전 세션 ────────\u{1B}[0m"

    private let root: URL

    init(root: URL = SessionSnapshotStore.defaultRoot) {
        self.root = root
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.local.myterminal", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// 되찍을 파일 경로. 남긴 것이 없으면 nil.
    func path(for id: UUID) -> String? {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    func write(_ text: String, for id: UUID) {
        let trimmed = Self.tail(of: text, maxLines: Self.maxLines, maxBytes: Self.maxBytes)
        guard !trimmed.isEmpty else {
            discard(id)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let body = "\(Self.marker)\n\(trimmed)\n"
            try Data(body.utf8).write(to: url(for: id), options: .atomic)
        } catch {
            Log.info("snapshot save failed — \(error.localizedDescription)")
        }
    }

    func discard(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// 배치에 남아 있지 않은 pane의 기록을 치운다. 창을 닫거나 탭을 닫은
    /// 세션의 파일이 계속 쌓이지 않게 앱을 켤 때 한 번 돈다.
    func discardOrphans(keeping live: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var removed = 0
        for file in files {
            let name = (file as NSString).deletingPathExtension
            guard let id = UUID(uuidString: name), !live.contains(id) else { continue }
            discard(id)
            removed += 1
        }
        if removed > 0 { Log.info("snapshots pruned — \(removed)") }
    }

    /// 뒤에서부터 줄 수와 바이트 수를 함께 재서 자른다. 두 기준 중 먼저
    /// 걸리는 쪽을 따른다 — 한 줄이 아주 긴 출력(로그 한 방울에 수십 KB)이
    /// 있어도 파일이 부풀지 않는다.
    static func tail(of text: String, maxLines: Int, maxBytes: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var bytes = 0

        for line in lines.reversed() {
            let size = line.utf8.count + 1
            if !kept.isEmpty, bytes + size > maxBytes { break }
            if kept.count >= maxLines { break }
            kept.append(line)
            bytes += size
        }
        return kept.reversed()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func url(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).txt")
    }
}
