import Foundation

@main
struct FolderAuditReplay {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            print("usage: folder-audit-replay <folder>")
            return
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let entries = FolderAuditEngine.candidateEntries(in: folder, limit: 80)
        var documents: [FolderAuditDocument] = []
        for entry in entries {
            documents.append(await FolderAuditEngine.auditDocument(for: entry))
        }
        let outliers = FolderAuditEngine.findOutliers(in: documents, parentFolder: folder)
        print("entries=\(entries.count) outliers=\(outliers.count)")
        for outlier in outliers {
            let topic = DocumentRelationshipEngine.specificTopicName(
                for: outlier.document.url, content: outlier.document.content
            ) ?? "unspecified"
            print("\(outlier.document.url.lastPathComponent) similarity=\(String(format: "%.3f", outlier.similarity)) median=\(String(format: "%.3f", outlier.medianSimilarity)) topic=\(topic)")
        }
    }
}
