import Foundation

@main
private struct RealReplay {
    static func main() async {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            fputs("usage: savepilot-real-replay FILE...\n", stderr)
            exit(2)
        }
        let engine = SuggestionEngine()
        for path in paths {
            let source = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: source.path) else {
                print("MISSING\t\(source.path)")
                continue
            }
            let content = await ContentExtractor.extract(from: source)
            let subject = AcademicSubjectClassifier.classify(source: source, content: content)
            let folder = engine.stableNewFolderName(for: source, content: content)
            let name = FileNameSuggester.suggest(source: source, content: content, academic: subject)?.fileName
            print([
                source.lastPathComponent,
                "kind=\(content.kind)",
                "subject=\(subject?.folderName ?? "none")",
                "folder=\(folder ?? "none")",
                "name=\(name ?? source.lastPathComponent)",
                "confidence=\(String(format: "%.3f", subject?.confidence ?? 0))"
            ].joined(separator: "\t"))
        }
    }
}
