import AppKit

@MainActor
enum DirectoryPicker {
    static func chooseRecordingDirectory(initialPath: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = AppLocalization.string("선택")
        panel.message = AppLocalization.string("녹화 파일을 저장할 폴더를 선택하세요.")

        let initial = Validate.normalizeRecordingOutputDir(initialPath)
        if initial != "." {
            panel.directoryURL = URL(fileURLWithPath: initial, isDirectory: true)
        }

        if panel.runModal() == .OK, let url = panel.url {
            completion(url.standardizedFileURL.path)
        }
    }
}
