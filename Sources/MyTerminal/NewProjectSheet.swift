import AppKit

/// 프로젝트를 새로 만드는 시트. 이름과 만들 위치만 받는다.
@MainActor
final class NewProjectSheet: FormSheet {
    /// 이름과 부모 디렉터리를 받아 만들고, 실패하면 사용자에게 보여 줄
    /// 메시지를 돌려준다. 성공하면 `nil`.
    var onSubmit: ((String, URL) async -> String?)?

    private let nameField = NSTextField()
    private let locationField = FormSheet.pathField(placeholder: ProjectStore.defaultRoot.path)

    init() {
        super.init(
            title: "새 프로젝트",
            subtitle: "이 위치 아래에 프로젝트 디렉터리를 만든다. 추가한 저장소의 worktree가 모두 그 안에 들어가고, 터미널도 거기서 열린다.",
            confirmTitle: "만들기"
        )
        locationField.stringValue = ProjectStore.defaultRoot.path
    }

    override func makeForm() -> NSView {
        nameField.placeholderString = "예: ax-refactor"

        let browseButton = NSButton(
            title: "찾아보기…",
            target: self,
            action: #selector(browse(_:))
        )
        browseButton.bezelStyle = .rounded
        browseButton.setContentHuggingPriority(.required, for: .horizontal)

        let locationRow = NSStackView(views: [locationField, browseButton])
        locationRow.orientation = .horizontal
        locationRow.spacing = 8

        let grid = NSGridView(views: [
            [FormSheet.label("이름"), nameField],
            [FormSheet.label("위치"), locationRow],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        return grid
    }

    override func confirm() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            show(error: "프로젝트 이름을 입력하세요.")
            return
        }

        let location = FormSheet.normalizedPath(locationField.stringValue)
        guard !location.isEmpty else {
            show(error: "프로젝트를 만들 위치를 입력하세요.")
            return
        }

        setBusy(true)
        Task {
            let failure = await onSubmit?(name, URL(fileURLWithPath: location, isDirectory: true))
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
        let current = FormSheet.normalizedPath(locationField.stringValue)
        FormSheet.chooseDirectory(
            startingAt: current.isEmpty ? nil : URL(fileURLWithPath: current, isDirectory: true),
            over: window
        ) { [weak self] url in
            self?.locationField.stringValue = url.path
        }
    }
}
