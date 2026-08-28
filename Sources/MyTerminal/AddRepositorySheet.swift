import AppKit

/// 프로젝트에 저장소를 붙이는 시트. 경로를 직접 치거나 탐색기로 고른다.
@MainActor
final class AddRepositorySheet: FormSheet {
    /// 저장소 경로를 받아 worktree를 만들고, 실패하면 사용자에게 보여 줄
    /// 메시지를 돌려준다. 성공하면 `nil`.
    var onSubmit: ((String) async -> String?)?

    private let pathField = FormSheet.pathField(placeholder: "~/workspace/my-repo")

    init(project: Project) {
        super.init(
            title: "레포 추가 — \(project.name)",
            subtitle: "고른 저장소의 worktree를 \(project.directory) 안에 만들고 \(project.branchName) 브랜치로 둔다. 원본 저장소의 작업 트리는 건드리지 않는다.",
            confirmTitle: "추가"
        )
    }

    override func makeForm() -> NSView {
        let browseButton = NSButton(
            title: "찾아보기…",
            target: self,
            action: #selector(browse(_:))
        )
        browseButton.bezelStyle = .rounded
        browseButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [pathField, browseButton])
        row.orientation = .horizontal
        row.spacing = 8

        let grid = NSGridView(views: [
            [FormSheet.label("저장소"), row],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        return grid
    }

    override func confirm() {
        let path = FormSheet.normalizedPath(pathField.stringValue)
        guard !path.isEmpty else {
            show(error: "저장소 경로를 입력하세요.")
            return
        }

        setBusy(true)
        Task {
            let failure = await onSubmit?(path)
            setBusy(false)
            guard let failure else {
                dismiss()
                return
            }
            show(error: failure)
        }
    }

    @objc private func browse(_: Any?) {
        guard let window else { return }
        let current = FormSheet.normalizedPath(pathField.stringValue)
        FormSheet.chooseDirectory(
            startingAt: current.isEmpty ? nil : URL(fileURLWithPath: current, isDirectory: true),
            over: window
        ) { [weak self] url in
            self?.pathField.stringValue = url.path
        }
    }
}
