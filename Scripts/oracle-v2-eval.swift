import Foundation

private struct ClassificationCase {
    let id: String
    let title: String
    let body: String
    let expected: String?
    let suite: String
}

private struct Metric {
    var correct = 0
    var total = 0
    mutating func record(_ value: Bool) { total += 1; if value { correct += 1 } }
    var accuracy: Double { Double(correct) / Double(max(1, total)) }
}

@main
private enum OracleV2Evaluation {
    static func main() {
        let cases = classificationCases()
        var suites: [String: Metric] = [:]
        var confusions: [String: Int] = [:]
        for item in cases {
            let actual = AcademicSubjectClassifier.classify(title: item.title, body: item.body)?.folderName
            suites[item.suite, default: Metric()].record(actual == item.expected)
            if actual != item.expected {
                confusions["\(item.expected ?? "拒绝")→\(actual ?? "拒绝")", default: 0] += 1
            }
        }
        var relation = Metric()
        evaluateRelationships(metric: &relation)
        var hierarchy = Metric()
        evaluateHierarchy(metric: &hierarchy)

        print("Oracle V2 — independently generated adversarial evaluation")
        for key in suites.keys.sorted() {
            let value = suites[key]!
            print(String(format: "classification/%@: %d/%d (%.3f)", key, value.correct, value.total, value.accuracy))
        }
        print(String(format: "relationship/order-and-hard-negatives: %d/%d (%.3f)", relation.correct, relation.total, relation.accuracy))
        print(String(format: "hierarchy/parent-child-and-siblings: %d/%d (%.3f)", hierarchy.correct, hierarchy.total, hierarchy.accuracy))
        if !confusions.isEmpty {
            print("confusions: " + confusions.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        let allClassificationPassed = suites.values.allSatisfy { $0.accuracy >= 0.90 }
        guard allClassificationPassed, relation.accuracy >= 0.95, hierarchy.accuracy >= 0.95 else { exit(1) }
    }

    private static func classificationCases() -> [ClassificationCase] {
        let subjects: [(String, [String], [String])] = [
            ("物理", ["oscillation laboratory", "field worksheet"], ["mechanics force acceleration momentum torque energy", "electric flux magnetic field optics quantum motion"]),
            ("数学", ["proof seminar", "analysis exercises"], ["algebra geometry theorem matrix vector equation proof", "calculus integral derivative differential function theorem"]),
            ("统计", ["inference memo", "survey analysis"], ["probability distribution variance sampling regression hypothesis", "bayes posterior random variable statistical sampling variance"]),
            ("经济学", ["policy brief", "market exercise"], ["economics supply demand elasticity utility equilibrium", "inflation monetary fiscal trade gdp macroeconomics"]),
            ("计算机", ["systems lab", "coding worksheet"], ["computer science algorithm compiler database network programming", "data structure operating system machine learning python algorithm"]),
            ("化学", ["titration record", "reaction worksheet"], ["chemistry molecule stoichiometry compound acid base reaction", "organic inorganic element molecule reaction compound chemistry"]),
            ("生物", ["genome seminar", "ecosystem fieldwork"], ["biology cell genetics dna protein enzyme evolution", "organism ecology evolution cell biological genetics"]),
            ("历史", ["civilization seminar", "archive notes"], ["world history ancient empire dynasty revolution civilization", "medieval war historical civilization empire revolution"]),
            ("语言", ["composition workshop", "syntax worksheet"], ["language grammar vocabulary literature reading writing essay", "linguistics syntax english grammar vocabulary writing"])
        ]
        let wrappers: [(String, (String) -> String)] = [
            ("clean", { $0 }),
            ("bilingual", { "课程资料 重点概念 course material " + $0 + " 作业复习" }),
            ("ocr-noise", { "SC4N_00l | page ## \($0) | xX unreadable 19B7" }),
            ("boilerplate", { "Student name date final version. Please answer every item. \($0). Copyright footer." })
        ]
        var result: [ClassificationCase] = []
        for (subjectIndex, subject) in subjects.enumerated() {
            for bodyIndex in subject.2.indices {
                for (wrapperIndex, wrapper) in wrappers.enumerated() {
                    result.append(ClassificationCase(
                        id: "subject-\(subjectIndex)-\(bodyIndex)-\(wrapperIndex)",
                        title: wrapperIndex == 0 ? subject.1[bodyIndex] : "scan_\(subjectIndex)_\(bodyIndex)_\(wrapperIndex)",
                        body: wrapper.1(subject.2[bodyIndex]), expected: subject.0, suite: wrapper.0
                    ))
                }
            }
            // Deliberately wrong filename: sufficiently rich body must win.
            let wrong = subjects[(subjectIndex + 3) % subjects.count].1[0]
            result.append(ClassificationCase(
                id: "misnamed-\(subjectIndex)", title: wrong,
                body: subject.2.joined(separator: " "), expected: subject.0, suite: "misleading-filename"
            ))
        }
        let negatives = [
            ("minutes", "meeting agenda attendees decisions follow up owner deadline"),
            ("receipt", "merchant subtotal payment card tax total purchase"),
            ("passport_scan", "name nationality date of birth expiration authority"),
            ("medical_form", "patient dosage appointment clinic insurance consent"),
            ("lease", "tenant landlord deposit property signature monthly payment"),
            ("travel", "rail hotel reservation luggage check in itinerary"),
            ("recipe", "oven butter flour salt servings preparation minutes"),
            ("design", "color typography layout logo spacing component palette"),
            ("untitled", "complete this before Friday and upload the final copy"),
            ("truth_effect", "repetition misinformation credibility memory social media")
        ]
        for (index, seed) in negatives.enumerated() {
            for variant in 0..<4 {
                result.append(ClassificationCase(
                    id: "abstain-\(index)-\(variant)",
                    title: variant == 0 ? seed.0 : "document_\(index)_\(variant)",
                    body: seed.1 + (variant == 2 ? " historical record model" : ""),
                    expected: nil, suite: "abstention-boundaries"
                ))
            }
        }
        return result
    }

    private static func evaluateRelationships(metric: inout Metric) {
        let modelingBodies = [
            "portfolio asset allocation optimization under risk constraint with expected return volatility stock",
            "投资组合优化模型使用股票资产、风险标准差和收益约束求最优配置",
            "Markowitz model: bank and stock asset allocation, optimal return subject to volatility risk constraints"
        ]
        let ieoBodies = [
            "IEO international economics olympiad microeconomics problem set supply demand competition",
            "国际经济学奥林匹克选拔赛题库，微观经济与宏观经济的供给需求分析",
            "economics competition practice on macroeconomics, microeconomics, market supply and demand"
        ]
        for (topic, bodies) in [("数学建模进阶课", modelingBodies), ("IEO经济学竞赛", ieoBodies)] {
            for left in bodies.indices {
                for right in bodies.indices where right != left {
                    let lhsURL = URL(fileURLWithPath: "/tmp/new_\(left).docx")
                    let rhsURL = URL(fileURLWithPath: "/tmp/peer_\(right).md")
                    let lhs = ExtractedContent(text: bodies[left], kind: "document", summary: bodies[left])
                    let rhs = ExtractedContent(text: bodies[right], kind: "document", summary: bodies[right])
                    let recommendation = DocumentRelationshipEngine.namedRecommendation(
                        for: lhsURL, content: lhs, corpus: [rhsURL.path: rhs]
                    )
                    metric.record(recommendation?.topicName == topic)
                }
            }
        }
        let hardNegatives = [
            ("portfolio website design asset color layout", "stock market return and public risk report"),
            ("model train railway schedule station return", "bank account statement asset balance"),
            ("economics mentioned in a bibliography only", "language olympiad competition writing essay"),
            ("supply chain delivery demand forecast", "microservice load balancing problem set"),
            ("historical volatility chart", "world history revolution empire archive")
        ]
        for (index, pair) in hardNegatives.enumerated() {
            let lhsURL = URL(fileURLWithPath: "/tmp/negative_l_\(index).docx")
            let rhsURL = URL(fileURLWithPath: "/tmp/negative_r_\(index).pdf")
            let lhs = ExtractedContent(text: pair.0, kind: "document", summary: pair.0)
            let rhs = ExtractedContent(text: pair.1, kind: "document", summary: pair.1)
            metric.record(DocumentRelationshipEngine.namedRecommendation(
                for: lhsURL, content: lhs, corpus: [rhsURL.path: rhs]
            ) == nil)
        }
    }

    private static func evaluateHierarchy(metric: inout Metric) {
        let base = URL(fileURLWithPath: "/tmp/oracle-v2", isDirectory: true)
        let cases: [(String, String, [String: Double], Bool)] = [
            ("lang", "ieo_archive", ["economics": 0.3, "supply": 0.2, "demand": 0.2, "market": 0.1], true),
            ("lang", "ieo_research", ["ieo": 0.3, "economics": 0.25, "olympiad": 0.2, "competition": 0.15], true),
            ("lang", "english_essays", ["english": 0.3, "grammar": 0.2, "writing": 0.2], false),
            ("history", "physics_lab", ["physics": 0.3, "mechanics": 0.2, "force": 0.2], true),
            ("math", "calculus", ["mathematics": 0.3, "integral": 0.2, "derivative": 0.2], false),
            ("biology", "chemistry_lab", ["chemistry": 0.3, "molecule": 0.2, "reaction": 0.2], true),
            ("computer science", "algorithms", ["computer": 0.2, "algorithm": 0.2, "database": 0.2], false)
        ]
        for (parent, child, weights, expectedConflict) in cases {
            let path = base.appendingPathComponent(parent).appendingPathComponent(child).path
            let profile = FolderKnowledgeProfile(
                path: path, weights: weights, extensions: ["pdf"], sampledFiles: 5,
                consideredFiles: 5, dominantFiles: 4, coherence: 0.72,
                hyperedges: [], updatedAt: Date()
            )
            metric.record((!FolderKnowledgeIndex.hierarchyConflicts(in: [profile]).isEmpty) == expectedConflict)
        }
        // A single file is not enough evidence to condemn a folder placement.
        let sparse = FolderKnowledgeProfile(
            path: base.appendingPathComponent("lang/physics_clip").path,
            weights: ["physics": 0.4, "force": 0.3, "motion": 0.2], extensions: ["pdf"],
            sampledFiles: 1, consideredFiles: 1, dominantFiles: 1, coherence: 1,
            hyperedges: [], updatedAt: Date()
        )
        metric.record(FolderKnowledgeIndex.hierarchyConflicts(in: [sparse]).isEmpty)
    }
}
