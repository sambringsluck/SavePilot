import Foundation

private struct OracleExample: Codable {
    let id: String
    let title: String
    let body: String
    let expected: String?
    let split: String
}

@main
private struct OracleEvaluation {
    static func main() {
        let examples = generateExamples()
        if CommandLine.arguments.contains("--jsonl") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for example in examples {
                if let data = try? encoder.encode(example), let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
            }
            return
        }
        evaluate(examples.filter { $0.split == "development" }, name: "development")
        evaluate(examples.filter { $0.split == "holdout" }, name: "holdout")
    }

    private static func generateExamples() -> [OracleExample] {
        let seeds: [(String, [(String, String)])] = [
            ("物理", [
                ("hw3", "AP Physics C Mechanics homework force motion energy momentum"),
                ("chapter22", "Gauss law electric flux electrostatic field and electromagnetism"),
                ("实验报告", "物理 力学 牛顿定律 动量与能量守恒实验")
            ]),
            ("数学", [
                ("problem-set", "calculus derivative integral theorem and differential equation"),
                ("线性代数作业", "矩阵 向量 特征值 线性方程 证明"),
                ("geometry-notes", "mathematics geometry trigonometry proof theorem")
            ]),
            ("统计", [
                ("stats-lab", "statistics probability distribution regression hypothesis variance"),
                ("概率作业", "统计学 概率 随机变量 分布 方差 抽样"),
                ("bayes-notes", "statistical bayes sampling posterior regression")
            ]),
            ("经济学", [
                ("ieo-practice", "economics market supply demand elasticity equilibrium gdp"),
                ("微观经济作业", "经济学 市场 供给 需求 效用 均衡"),
                ("macro-notes", "macroeconomics inflation monetary fiscal trade labor growth")
            ]),
            ("计算机", [
                ("cs-homework", "computer science algorithm data structure programming database"),
                ("算法笔记", "计算机科学 算法 数据结构 编程 数据库"),
                ("ml-course", "machine learning python algorithm network model training")
            ]),
            ("化学", [
                ("chem-lab", "chemistry molecule reaction compound acid base stoichiometry"),
                ("有机化学作业", "化学 有机 分子 反应 元素 化合物"),
                ("chapter-acid", "inorganic chemistry reaction acid base element")
            ]),
            ("生物", [
                ("bio-lab", "biology cell genetics dna protein enzyme evolution"),
                ("遗传学作业", "生物学 细胞 遗传 进化 蛋白质"),
                ("ecology-notes", "biological organism ecology evolution cell")
            ]),
            ("历史", [
                ("global-history", "world history civilization empire ancient revolution dynasty"),
                ("全球通史", "历史 世界史 文明 帝国 古代 王朝 革命"),
                ("medieval-notes", "historical medieval empire war civilization")
            ]),
            ("语言", [
                ("english-homework", "english language grammar vocabulary reading writing essay"),
                ("语文阅读", "语言 语文 阅读 写作 文学 词汇"),
                ("linguistics", "linguistics syntax grammar language vocabulary")
            ])
        ]
        let noise = [
            "", "student course notes", "final version document", "Beijing National Day School",
            "Please complete all questions before class"
        ]
        var examples: [OracleExample] = []
        for (subject, subjectSeeds) in seeds {
            for (seedIndex, seed) in subjectSeeds.enumerated() {
                for (noiseIndex, suffix) in noise.enumerated() {
                    examples.append(OracleExample(
                        id: "\(subject)-\(seedIndex)-\(noiseIndex)",
                        title: noiseIndex.isMultiple(of: 2) ? seed.0 : "document_\(noiseIndex)",
                        body: seed.1 + " " + suffix,
                        expected: subject,
                        split: noiseIndex == noise.count - 1 ? "holdout" : "development"
                    ))
                }
            }
        }
        let negatives: [(String, String)] = [
            ("integrity_statement", "I affirm this submission is original and follows the honor code"),
            ("interview_notes", "client interview resume meeting proposal and hiring feedback"),
            ("invoice_2026", "invoice bank account payment total tax statement"),
            ("vacation_plan", "flight hotel booking museum beach visa itinerary"),
            ("Propaganda", "misinformation persuasion media public opinion and truth"),
            ("hw4", "Complete questions one through ten before next class"),
            ("medical_record", "hospital diagnosis prescription patient health"),
            ("contract_final", "legal agreement signature terms and parties"),
            ("portfolio_model", "investment return risk correlation historical data optimal portfolio bank stock")
        ]
        for repeatIndex in 0..<5 {
            for (index, seed) in negatives.enumerated() {
                examples.append(OracleExample(
                    id: "negative-\(index)-\(repeatIndex)",
                    title: repeatIndex.isMultiple(of: 2) ? seed.0 : "document_\(repeatIndex)",
                    body: seed.1 + (repeatIndex == 3 ? " general report project" : ""),
                    expected: nil,
                    split: repeatIndex == 4 ? "holdout" : "development"
                ))
            }
        }
        return examples
    }

    private static func evaluate(_ examples: [OracleExample], name: String) {
        var correct = 0
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        var confusions: [String: Int] = [:]
        for example in examples {
            let predicted = AcademicSubjectClassifier.classify(title: example.title, body: example.body)?.folderName
            if predicted == example.expected { correct += 1 }
            if predicted != nil, example.expected != nil, predicted == example.expected { truePositive += 1 }
            else if predicted != nil, predicted != example.expected { falsePositive += 1 }
            else if predicted == nil, example.expected != nil { falseNegative += 1 }
            if predicted != example.expected {
                confusions["\(example.expected ?? "none")→\(predicted ?? "none")", default: 0] += 1
            }
        }
        let accuracy = Double(correct) / Double(max(1, examples.count))
        let precision = Double(truePositive) / Double(max(1, truePositive + falsePositive))
        let recall = Double(truePositive) / Double(max(1, truePositive + falseNegative))
        print(String(format: "%@: n=%d accuracy=%.3f precision=%.3f recall=%.3f", name, examples.count, accuracy, precision, recall))
        if !confusions.isEmpty {
            print("confusions:", confusions.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        if name == "holdout", accuracy < 0.90 || precision < 0.92 || recall < 0.88 {
            exit(1)
        }
    }
}
