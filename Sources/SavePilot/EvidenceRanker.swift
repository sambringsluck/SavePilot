import Foundation

struct FolderEvidenceCandidate: Sendable {
    let identifier: String
    let semantic: Double
    let hypergraph: Double
    let pathMatch: Double
    let extensionMatch: Double
    let coherence: Double
    let evidenceTermCount: Int
}

struct FolderEvidenceRanking: Sendable {
    let identifier: String
    let quality: Double
    let margin: Double
    let confidence: Double
    let channels: [String]
}

/// Combines independently-scaled retrieval signals by rank before applying an
/// absolute-quality and winner-margin gate. This keeps one noisy signal from
/// overpowering the others and explicitly abstains on close or weak results.
enum EvidenceRanker {
    static func rank(_ candidates: [FolderEvidenceCandidate]) -> FolderEvidenceRanking? {
        guard candidates.count >= 2 else { return nil }

        let semanticRanks = ranks(candidates, value: { $0.semantic }, minimum: 0.045)
        let hypergraphRanks = ranks(candidates, value: { $0.hypergraph }, minimum: 0.025)
        let pathRanks = ranks(candidates, value: { $0.pathMatch }, minimum: 0.055)
        let extensionRanks = ranks(candidates, value: { $0.extensionMatch }, minimum: 0.5)

        let scored = candidates.map { candidate -> (FolderEvidenceCandidate, Double, Double, [String]) in
            var fusion = 0.0
            var channels: [String] = []
            if let rank = semanticRanks[candidate.identifier] {
                fusion += reciprocal(rank, weight: 1.0)
                channels.append("正文主题")
            }
            if let rank = hypergraphRanks[candidate.identifier] {
                fusion += reciprocal(rank, weight: 0.78)
                channels.append("共享实体/关键词")
            }
            if let rank = pathRanks[candidate.identifier] {
                fusion += reciprocal(rank, weight: 0.90)
                channels.append("文件名/目录名")
            }
            if let rank = extensionRanks[candidate.identifier] {
                fusion += reciprocal(rank, weight: 0.12)
                channels.append("格式习惯")
            }

            let semanticQuality = min(1, candidate.semantic / 0.26)
            let graphQuality = min(1, candidate.hypergraph / 0.16)
            let pathQuality = min(1, candidate.pathMatch / 0.20)
            let absolute = semanticQuality * 0.64
                + graphQuality * 0.18
                + pathQuality * 0.15
                + candidate.extensionMatch * 0.03
            let coherenceFactor = 0.72 + min(0.28, max(0, candidate.coherence) * 0.28)
            let normalizedFusion = min(1, fusion / 0.30)
            let quality = (absolute * 0.78 + normalizedFusion * 0.22) * coherenceFactor
            return (candidate, quality, fusion, channels)
        }.sorted {
            if abs($0.1 - $1.1) > 0.000_001 { return $0.1 > $1.1 }
            return $0.2 > $1.2
        }

        guard let best = scored.first else { return nil }
        let secondQuality = scored.dropFirst().first?.1 ?? 0
        let margin = best.1 - secondQuality
        let strongChannels = best.3.filter { $0 != "格式习惯" }

        guard best.0.evidenceTermCount >= 2,
              best.0.semantic >= 0.065,
              best.1 >= 0.34,
              margin >= 0.055,
              !strongChannels.isEmpty,
              (strongChannels.count >= 2 || best.0.semantic >= 0.17)
        else { return nil }

        let confidence = min(0.96, 0.54 + best.1 * 0.34 + margin * 0.48)
        return FolderEvidenceRanking(
            identifier: best.0.identifier,
            quality: best.1,
            margin: margin,
            confidence: confidence,
            channels: best.3
        )
    }

    private static func ranks(
        _ candidates: [FolderEvidenceCandidate],
        value: (FolderEvidenceCandidate) -> Double,
        minimum: Double
    ) -> [String: Int] {
        let eligible = candidates
            .filter { value($0) >= minimum }
            .sorted { value($0) > value($1) }
        return Dictionary(uniqueKeysWithValues: eligible.enumerated().map { ($0.element.identifier, $0.offset + 1) })
    }

    private static func reciprocal(_ rank: Int, weight: Double) -> Double {
        weight / Double(8 + rank)
    }
}
