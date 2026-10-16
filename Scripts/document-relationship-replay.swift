import Foundation

@main
struct DocumentRelationshipReplay {
    static func main() async {
        guard CommandLine.arguments.count >= 3 else {
            print("usage: document-relationship-replay <file-a> <file-b> [file-c ...]")
            return
        }
        if CommandLine.arguments.count > 3 {
            let urls = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
            var contents: [String: ExtractedContent] = [:]
            var suggestions: [FileSuggestion] = []
            for url in urls {
                let content = await ContentExtractor.extract(from: url)
                contents[url.standardizedFileURL.path] = content
                suggestions.append(FileSuggestion(
                    id: UUID(), source: url, destinationFolder: url.deletingLastPathComponent(),
                    proposedFolderName: "", reason: "baseline", summary: content.summary,
                    confidence: 0.5, createsFolder: false, detectedAt: Date()
                ))
            }
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
            let resolved = RelatedFileConsensus.consolidate(suggestions, contents: contents, roots: [root])
            for suggestion in resolved {
                print("\(suggestion.source.lastPathComponent) -> \(suggestion.finalDestinationFolder.path)")
            }
            return
        }
        let leftURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let rightURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let left = await ContentExtractor.extract(from: leftURL)
        let right = await ContentExtractor.extract(from: rightURL)
        if let relation = DocumentRelationshipEngine.compare(
            lhsURL: leftURL, lhs: left, rhsURL: rightURL, rhs: right
        ) {
            print("related score=\(String(format: "%.3f", relation.score)) topic=\(relation.topicName ?? "generic") terms=\(relation.sharedTerms.joined(separator: ","))")
        } else {
            print("not-related")
        }
    }
}
