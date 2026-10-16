import Foundation

struct UserProfileSnapshot: Codable, Sendable {
    var academicAffinity: [String: Double]
    var observedLooseFiles: Int
    var profiledFolders: Int
    var sampledFiles: Int
    var updatedAt: Date

    static let empty = UserProfileSnapshot(
        academicAffinity: [:], observedLooseFiles: 0,
        profiledFolders: 0, sampledFiles: 0, updatedAt: .distantPast
    )

    var summary: String {
        let interests = academicAffinity.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        let interestText = interests.isEmpty ? "尚未形成稳定学科偏好" : "主要学科：" + interests.joined(separator: "、")
        return "\(interestText)；画像来自 \(profiledFolders) 个已有文件夹、\(sampledFiles) 个抽样文件和 \(observedLooseFiles) 个散落文件"
    }
}

struct AcademicSubjectMatch: Sendable {
    let folderName: String
    let score: Double
    let margin: Double
    let confidence: Double
    let evidence: [String]
}

enum AcademicSubjectClassifier {
    struct Subject: Sendable {
        let folder: String
        let aliases: [String]
        let keywords: [String]
    }

    static let subjects: [Subject] = [
        .init(folder: "物理", aliases: ["physics", "ap physics", "物理"], keywords: [
            "mechanics", "kinematics", "dynamics", "newton", "force", "motion", "energy", "momentum",
            "rotation", "torque", "thermodynamics", "electric", "electricity", "electromagnetism", "magnetism",
            "gauss", "flux", "optics", "quantum", "relativity", "物理", "力学", "电磁", "热力学", "光学", "动量"
        ]),
        .init(folder: "数学", aliases: ["mathematics", "math", "数学", "calculus", "微积分"], keywords: [
            "algebra", "geometry", "trigonometry", "derivative", "integral", "theorem", "matrix", "vector",
            "differential", "equation", "proof", "函数", "代数", "几何", "导数", "积分", "定理", "矩阵", "方程"
        ]),
        .init(folder: "统计", aliases: ["statistics", "statistical", "统计学", "统计"], keywords: [
            "probability", "regression", "distribution", "hypothesis", "variance", "bayes", "sampling", "random variable",
            "概率", "回归", "分布", "假设检验", "方差", "贝叶斯", "抽样"
        ]),
        .init(folder: "经济学", aliases: ["economics", "microeconomics", "macroeconomics", "经济学", "微观经济", "宏观经济"], keywords: [
            "market", "supply", "demand", "utility", "inflation", "gdp", "elasticity", "externality", "equilibrium",
            "labor", "trade", "monetary", "fiscal", "市场", "供给", "需求", "效用", "通胀", "均衡", "博弈"
        ]),
        .init(folder: "计算机", aliases: ["computer science", "computing", "计算机科学", "计算机"], keywords: [
            "algorithm", "data structure", "programming", "compiler", "database", "network", "operating system",
            "machine learning", "python", "java", "swift", "算法", "数据结构", "编程", "数据库", "机器学习"
        ]),
        .init(folder: "化学", aliases: ["chemistry", "化学"], keywords: [
            "molecule", "reaction", "organic", "inorganic", "stoichiometry", "element", "compound", "acid", "base",
            "分子", "反应", "有机", "无机", "元素", "化合物", "酸碱"
        ]),
        .init(folder: "生物", aliases: ["biology", "biological", "生物学", "生物"], keywords: [
            "cell", "genetics", "evolution", "ecology", "organism", "dna", "protein", "enzyme", "细胞", "遗传", "进化", "生态", "蛋白质"
        ]),
        .init(folder: "历史", aliases: ["history", "historical", "world history", "global history", "历史", "世界史", "通史"], keywords: [
            "civilization", "empire", "ancient", "medieval", "revolution", "dynasty", "war", "文明", "帝国", "古代", "中世纪", "革命", "王朝"
        ]),
        .init(folder: "语言", aliases: ["language", "linguistics", "english", "chinese", "语言", "英语", "语文"], keywords: [
            "grammar", "vocabulary", "reading", "writing", "literature", "essay", "syntax", "语法", "词汇", "阅读", "写作", "文学"
        ])
    ]

    static func classify(
        source: URL,
        content: ExtractedContent,
        profile: UserProfileSnapshot? = nil
    ) -> AcademicSubjectMatch? {
        classify(
            title: source.deletingPathExtension().lastPathComponent,
            body: "\(content.summary) \(content.entities.joined(separator: " ")) \(String(content.text.prefix(12_000)))",
            profile: profile
        )
    }

    static func classify(
        title: String,
        body: String,
        profile: UserProfileSnapshot? = nil
    ) -> AcademicSubjectMatch? {
        let title = normalized(title)
        let body = normalized(body)
        let ranked = subjects.map { subject -> (Subject, Double, Int, Bool, Bool, [String]) in
            var score = 0.0
            var hits = Set<String>()
            var titleAlias = false
            var bodyAlias = false
            for alias in subject.aliases {
                if contains(alias, in: title) {
                    score += 5.0
                    hits.insert(alias)
                    titleAlias = true
                } else if contains(alias, in: body) {
                    score += 2.8
                    hits.insert(alias)
                    bodyAlias = true
                }
            }
            let aliasSignals = Set(subject.aliases.map { normalized($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            for keyword in subject.keywords
            where !aliasSignals.contains(normalized(keyword).trimmingCharacters(in: .whitespacesAndNewlines))
                    && (contains(keyword, in: title) || contains(keyword, in: body)) {
                score += contains(keyword, in: title) ? 1.8 : 1.0
                hits.insert(keyword)
            }
            // Personal history can break a close tie, but it can never create
            // a subject match without at least two current-file signals.
            if hits.count >= 2, let affinity = profile?.academicAffinity[subject.folder] {
                score += min(0.35, log1p(max(0, affinity)) * 0.10)
            }
            return (subject, score, hits.count, titleAlias, bodyAlias, Array(hits).sorted())
        }.sorted { $0.1 > $1.1 }

        guard let best = ranked.first else { return nil }
        let second = ranked.dropFirst().first?.1 ?? 0
        let margin = best.1 - second
        let hasEnoughEvidence: Bool
        if best.3 {
            hasEnoughEvidence = best.1 >= 4.0
        } else if best.4 {
            // A subject word in the body can be incidental (for example,
            // “historical data” in a finance model). Require at least one
            // additional, distinct current-file signal.
            hasEnoughEvidence = best.2 >= 2 && best.1 >= 3.8
        } else {
            hasEnoughEvidence = best.2 >= 3 && best.1 >= 3.0
        }
        guard hasEnoughEvidence, margin >= 1.0 else { return nil }
        let confidence = min(0.97, 0.58 + best.1 * 0.045 + margin * 0.035)
        return AcademicSubjectMatch(
            folderName: best.0.folder,
            score: best.1,
            margin: margin,
            confidence: confidence,
            evidence: Array(best.5.prefix(8))
        )
    }

    static func aliases(for folderName: String) -> [String] {
        guard let subject = subjects.first(where: { $0.folder == folderName }) else { return [] }
        return [subject.folder] + subject.aliases
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[_\\/\\-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func contains(_ signal: String, in evidence: String) -> Bool {
        let signal = normalized(signal).trimmingCharacters(in: .whitespacesAndNewlines)
        guard signal.count >= 2 else { return false }
        if signal.contains(where: { !$0.isASCII }) || signal.contains(" ") {
            return evidence.contains(signal)
        }
        let tokens = Set(evidence.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return tokens.contains(signal)
    }
}
