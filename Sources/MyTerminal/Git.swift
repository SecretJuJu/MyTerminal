import Foundation

struct GitError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// `/usr/bin/git` 호출 래퍼.
///
/// worktree를 뜨는 동안은 작업 트리 전체가 디스크에 풀린다. 큰 저장소에서는
/// 몇 초가 걸리므로 메인 스레드에서 돌리면 창이 그대로 굳는다. 전부
/// 백그라운드에서 실행하고 결과만 넘긴다.
enum Git {
    private static let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    /// 저장소 최상위 경로. 사용자가 하위 디렉터리를 골라도 최상위로 올라간다.
    static func repositoryRoot(at path: String) async throws -> String {
        do {
            return try await run(["-C", path, "rev-parse", "--show-toplevel"])
        } catch {
            throw GitError(message: "git 저장소가 아닙니다: \(path)")
        }
    }

    static func commonDirectory(at repository: String) async throws -> String {
        try await run([
            "-C", repository, "rev-parse", "--path-format=absolute", "--git-common-dir",
        ])
    }

    static func branchExists(_ branch: String, in repository: String) async -> Bool {
        do {
            _ = try await run([
                "-C", repository, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)",
            ])
            return true
        } catch {
            return false
        }
    }

    /// 이 브랜치를 이미 물고 있는 worktree 경로. 원본 저장소의 작업 트리도
    /// worktree 하나로 세므로, 사용자가 그 브랜치를 체크아웃해 둔 경우도 잡힌다.
    static func worktreePath(forBranch branch: String, in repository: String) async -> String? {
        guard let listing = try? await run([
            "-C", repository, "worktree", "list", "--porcelain",
        ]) else { return nil }

        var current: String?
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                current = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)" {
                return current
            }
        }
        return nil
    }

    /// 브랜치가 없으면 현재 HEAD에서 새로 만들고, 있으면 그대로 체크아웃한다.
    static func addWorktree(
        repository: String,
        destination: String,
        branch: String
    ) async throws {
        // 미리 확인해서 어디를 치우면 되는지 알려 준다. git도 막아 주기는
        // 하지만 "is already used by worktree at ..."만 던지고 끝이라,
        // 어느 프로젝트가 물고 있는지 사용자가 직접 찾아야 한다.
        if let occupied = await worktreePath(forBranch: branch, in: repository) {
            throw GitError(
                message: """
                ‘\(branch)’ 브랜치를 이미 다른 곳에서 쓰고 있습니다.
                \(occupied)
                그쪽 worktree를 옮기거나 지운 뒤 다시 시도하세요.
                """
            )
        }

        var arguments = ["-C", repository, "worktree", "add"]
        if await branchExists(branch, in: repository) {
            arguments += [destination, branch]
        } else {
            arguments += ["-b", branch, destination]
        }
        _ = try await run(arguments)
    }

    /// `--force`를 붙이지 않는다. 커밋하지 않은 변경이 남은 worktree는
    /// git이 막아 세우는 편이 낫다 — 우리가 대신 지워 줄 일이 아니다.
    static func removeWorktree(repository: String, destination: String) async throws {
        do {
            _ = try await run(["-C", repository, "worktree", "remove", destination])
        } catch let error as GitError
            where error.message.contains("contains modified or untracked files")
        {
            // git은 `--force`를 쓰라고 안내하지만 우리에겐 그 버튼이 없다.
            // 사용자가 실제로 할 수 있는 일을 말해 준다.
            throw GitError(
                message: "커밋하지 않은 변경이나 추적되지 않는 파일이 남아 있어 지우지 않았습니다."
            )
        }
    }

    @discardableResult
    static func run(_ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let temporary = FileManager.default.temporaryDirectory
            let outputURL = temporary
                .appendingPathComponent("myterminal-git-\(UUID().uuidString).out")
            let errorURL = temporary
                .appendingPathComponent("myterminal-git-\(UUID().uuidString).err")
            defer {
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: errorURL)
            }
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)

            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            // 자격 증명 프롬프트가 뜨면 답해 줄 터미널이 없어 그대로 매달린다.
            environment["GIT_TERMINAL_PROMPT"] = "0"
            process.environment = environment

            // 파이프 대신 임시 파일로 받는다. 파이프는 64KB 버퍼가 차는 순간
            // git이 write()에서 멈추는데, 그동안 우리는 오지 않을 종료를
            // 기다리게 된다. 한쪽만 비우는 구현은 출력이 짧을 때만 우연히 산다.
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
            }
            process.standardOutput = outputHandle
            process.standardError = errorHandle

            do {
                try process.run()
            } catch {
                throw GitError(message: "git을 실행할 수 없습니다: \(error.localizedDescription)")
            }
            process.waitUntilExit()

            let standardOutput = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            let standardError = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""

            guard process.terminationStatus == 0 else {
                let detail = standardError.isEmpty ? standardOutput : standardError
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                throw GitError(
                    message: trimmed.isEmpty
                        ? "git \(arguments.joined(separator: " ")) 실패 (\(process.terminationStatus))"
                        : trimmed
                )
            }

            return standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
