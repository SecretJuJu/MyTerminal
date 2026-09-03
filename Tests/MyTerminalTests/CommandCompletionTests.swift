import Foundation
import Testing

@testable import MyTerminal

@Suite("자동완성")
@MainActor
struct CommandCompletionTests {
    /// 디스크 대신 이 목록을 본다.
    private func sources(
        files: [String: [(name: String, isDirectory: Bool)]] = [:],
        executables: [String] = []
    ) -> CommandCompletion.Sources {
        CommandCompletion.Sources(
            listDirectory: { files[$0] ?? [] },
            executables: { executables }
        )
    }

    @Test("첫 낱말은 명령 이름으로 완성한다")
    func completesCommandNames() {
        // #given
        let sources = sources(executables: ["git", "gitk", "grep", "make"])

        // #when
        let result = CommandCompletion.complete(
            text: "gi",
            caret: 2,
            workingDirectory: "/work",
            sources: sources
        )

        // #then
        #expect(result?.candidates == ["git", "gitk"])
        #expect(result?.commonPrefix == "git")
        #expect(result?.range == NSRange(location: 0, length: 2))
    }

    @Test("인자 자리는 파일 이름으로 완성하고 디렉터리에는 빗금을 붙인다")
    func completesPathsForArguments() {
        // #given
        let sources = sources(files: [
            "/work": [("Sources", true), ("README.md", false), ("Package.swift", false)],
        ])

        // #when
        let result = CommandCompletion.complete(
            text: "cat R",
            caret: 5,
            workingDirectory: "/work",
            sources: sources
        )
        let directory = CommandCompletion.complete(
            text: "cd So",
            caret: 5,
            workingDirectory: "/work",
            sources: sources
        )

        // #then
        #expect(result?.candidates == ["README.md"])
        #expect(directory?.candidates == ["Sources/"])
    }

    @Test("경로 중간부터 이어서 완성한다")
    func completesNestedPaths() {
        // #given
        let sources = sources(files: [
            "/work/Sources": [("MyTerminal", true), ("main.swift", false)],
        ])

        // #when
        let result = CommandCompletion.complete(
            text: "ls Sources/m",
            caret: 12,
            workingDirectory: "/work",
            sources: sources
        )

        // #then — 바꿔 넣을 자리는 토큰 전체다
        #expect(result?.candidates == ["Sources/main.swift"])
        #expect(result?.range == NSRange(location: 3, length: 9))
    }

    @Test("숨김 파일은 점을 찍었을 때만 보여 준다")
    func hidesDotfilesUnlessAsked() {
        // #given
        let sources = sources(files: [
            "/work": [(".git", true), (".gitignore", false), ("Package.swift", false)],
        ])

        // #when
        let plain = CommandCompletion.complete(
            text: "ls ",
            caret: 3,
            workingDirectory: "/work",
            sources: sources
        )
        let dotted = CommandCompletion.complete(
            text: "ls .g",
            caret: 5,
            workingDirectory: "/work",
            sources: sources
        )

        // #then
        #expect(plain?.candidates == ["Package.swift"])
        #expect(dotted?.candidates == [".git/", ".gitignore"])
    }

    @Test("물결표는 홈 디렉터리로 푼다")
    func expandsTilde() {
        // #given
        let sources = sources(files: [
            "/Users/tester": [("Downloads", true)],
        ])

        // #when
        let result = CommandCompletion.complete(
            text: "cd ~/Dow",
            caret: 8,
            workingDirectory: "/work",
            home: "/Users/tester",
            sources: sources
        )

        // #then
        #expect(result?.candidates == ["~/Downloads/"])
    }

    @Test("파이프 뒤는 다시 명령 자리다")
    func treatsPipeAsCommandBoundary() {
        // #given
        let utf16 = Array("ls | gr".utf16)

        // #when
        let start = CommandCompletion.tokenStart(in: utf16, before: utf16.count)
        let isCommand = CommandCompletion.isCommandPosition(in: utf16, tokenStart: start)

        // #then
        #expect(start == 5)
        #expect(isCommand)
    }

    @Test("이스케이프한 공백은 한 낱말로 본다")
    func keepsEscapedSpacesInToken() {
        // #given
        let utf16 = Array("cat My\\ Fi".utf16)

        // #when
        let start = CommandCompletion.tokenStart(in: utf16, before: utf16.count)

        // #then
        #expect(start == 4)
    }

    @Test("공백이 든 이름은 셸이 한 낱말로 읽게 적는다")
    func escapesSpacesInCandidates() {
        // #given
        let sources = sources(files: [
            "/work": [("My File.txt", false)],
        ])

        // #when
        let result = CommandCompletion.complete(
            text: "cat My",
            caret: 6,
            workingDirectory: "/work",
            sources: sources
        )

        // #then
        #expect(result?.candidates == ["My\\ File.txt"])
    }

    @Test("맞는 것이 없으면 아무것도 돌려주지 않는다")
    func returnsNilWhenNothingMatches() {
        // #given
        let sources = sources(files: ["/work": [("README.md", false)]], executables: ["git"])

        // #when
        let result = CommandCompletion.complete(
            text: "cat zzz",
            caret: 7,
            workingDirectory: "/work",
            sources: sources
        )

        // #then
        #expect(result == nil)
    }
}
