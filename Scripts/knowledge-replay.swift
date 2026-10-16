import Foundation

@main
private struct KnowledgeReplay {
    static func main() async {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            fputs("usage: savepilot-knowledge-replay FILE...\n", stderr)
            exit(2)
        }
        let profiles = FolderKnowledgeIndex.load()
        print("profiles=\(profiles.count)")
        for path in paths {
            let source = URL(fileURLWithPath: path).standardizedFileURL
            let content = await ContentExtractor.extract(from: source)
            let recommendation = FolderKnowledgeIndex.recommend(
                source: source,
                content: content,
                profiles: profiles
            )
            if let recommendation {
                print([
                    source.lastPathComponent,
                    "destination=\(recommendation.destination.path)",
                    "confidence=\(String(format: "%.3f", recommendation.confidence))",
                    "margin=\(String(format: "%.3f", recommendation.margin))",
                    "channels=\(recommendation.evidenceChannels.joined(separator: "+"))",
                    "terms=\(recommendation.evidenceTerms.joined(separator: ","))"
                ].joined(separator: "\t"))
            } else {
                print("\(source.lastPathComponent)\tdestination=none")
            }
        }
    }
}
