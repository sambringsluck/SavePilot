#!/usr/bin/env python3
"""Generate boundary-focused file relationship cases.

The built-in corpus is deterministic and redistributable.  The optional
20-Newsgroups adapter downloads the public benchmark through scikit-learn and
emits same-class positives plus nearby-category hard negatives.  Downloaded
text is never committed by this script unless the caller explicitly chooses an
output path outside the ignored Training/generated directory.
"""

from __future__ import annotations

import argparse
import json
import random
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass
class HardCase:
    case_id: str
    left_name: str
    left_text: str
    right_name: str
    right_text: str
    should_link: bool
    expected_topic: str | None
    confusion: str
    source: str = "SavePilot boundary templates"


TOPICS = {
    "portfolio": [
        ("建模2.docx", "投资组合模型在风险约束下优化股票资产配置，使预期收益最大，并讨论标准差。"),
        ("金融数据问题讨论.md", "用 Markowitz portfolio optimization 分配股票和银行资产，权衡 expected return 与 volatility risk。"),
        ("课堂笔记.pdf", "资产配置的最优约束包含风险、收益、股票权重、银行无风险利率。"),
        ("model-answer.txt", "Optimal portfolio model maximizes return subject to stock volatility and bank allocation constraints."),
    ],
    "ieo": [
        ("IEO题库.pdf", "International Economics Olympiad competition problem set on microeconomics supply and demand."),
        ("各国选拔赛.md", "IEO 国际经济学奥林匹克选拔赛真题，覆盖微观经济和宏观经济。"),
        ("economics-bank.docx", "IEO competition economics problem set: microeconomics, macroeconomics, demand and supply."),
    ],
}

HARD_NEGATIVES = [
    HardCase("neg-author-project", "van Linden.docx", "Van der Linden studies misinformation repetition and perceived truth.", "数学竞赛提交.pdf", "Van der Linden appears once in a bibliography for an unrelated geometry competition submission.", False, None, "same author token, different destination purpose"),
    HardCase("neg-historical-data", "全球通史.docx", "World history examines ancient civilizations, empires and revolutions.", "portfolio.csv", "Historical return data estimates portfolio volatility and expected investment return.", False, None, "historical is not history"),
    HardCase("neg-force", "力学作业.pdf", "Physics force mass acceleration energy and momentum.", "contract.docx", "A legal force majeure clause governs the agreement and signatures.", False, None, "polysemous word force"),
    HardCase("neg-java", "Java课程.java", "Java class interface compiler and object oriented programming.", "java-trip.md", "Travel itinerary for Java island hotel flight beach and museum.", False, None, "entity ambiguity"),
    HardCase("neg-apple", "Apple财报.pdf", "Apple company revenue product sales and quarterly financial results.", "apple-recipe.md", "Apple fruit pie recipe with cinnamon sugar and pastry.", False, None, "company versus fruit"),
    HardCase("neg-finance-invoice", "portfolio-model.docx", TOPICS["portfolio"][0][1], "invoice.pdf", "Bank invoice receipt, tax amount due, payment account and purchase total.", False, None, "same broad finance category, different workflow"),
    HardCase("neg-language-ieo", "english-essay.docx", "English grammar vocabulary reading literature essay and syntax.", "IEO题库.pdf", TOPICS["ieo"][0][1], False, None, "competition material misplaced under language"),
]


def built_in_cases() -> list[HardCase]:
    base: list[HardCase] = []
    for topic, samples in TOPICS.items():
        folder = "数学建模进阶课" if topic == "portfolio" else "IEO经济学竞赛"
        for index, left in enumerate(samples):
            for right in samples[index + 1:]:
                base.append(HardCase(
                    f"pos-{topic}-{index}-{samples.index(right)}",
                    left[0], left[1], right[0], right[1], True, folder,
                    "same project expressed with different wording",
                ))
    base.extend(HARD_NEGATIVES)

    # Apply realistic packaging noise rather than merely duplicating labels:
    # weak filenames, exported-chat boilerplate, OCR spacing, and reversed
    # pair order. These are common ways an otherwise correct relation breaks.
    wrappers = [
        ("raw", lambda text: text, lambda name, side: name),
        ("generic-name", lambda text: text, lambda name, side: f"scan00{side}{Path(name).suffix or '.txt'}"),
        ("export", lambda text: f"Conversation export User Assistant Document Content {text}", lambda name, side: f"export-{side}.md"),
        ("ocr", lambda text: " \n ".join(text.split()), lambda name, side: f"IMG_20{side}.pdf"),
    ]
    result: list[HardCase] = []
    for case in base:
        for suffix, wrap_text, wrap_name in wrappers:
            result.append(HardCase(
                f"{case.case_id}-{suffix}",
                wrap_name(case.left_name, 1), wrap_text(case.left_text),
                wrap_name(case.right_name, 2), wrap_text(case.right_text),
                case.should_link, case.expected_topic, case.confusion, case.source,
            ))
            result.append(HardCase(
                f"{case.case_id}-{suffix}-reversed",
                wrap_name(case.right_name, 2), wrap_text(case.right_text),
                wrap_name(case.left_name, 1), wrap_text(case.left_text),
                case.should_link, case.expected_topic, case.confusion, case.source,
            ))
    return result


def newsgroups_cases(limit: int, seed: int) -> list[HardCase]:
    try:
        from sklearn.datasets import fetch_20newsgroups
    except ImportError as error:
        raise SystemExit("Install scikit-learn to use --with-20-newsgroups") from error
    categories = [
        "comp.graphics", "comp.os.ms-windows.misc", "comp.sys.mac.hardware",
        "sci.electronics", "sci.med", "sci.space",
        "talk.politics.misc", "talk.religion.misc", "soc.religion.christian",
    ]
    dataset = fetch_20newsgroups(subset="train", categories=categories, remove=("headers", "footers", "quotes"))
    grouped: dict[int, list[str]] = {}
    for text, label in zip(dataset.data, dataset.target):
        if len(text.strip()) >= 200:
            grouped.setdefault(int(label), []).append(" ".join(text.split())[:5_000])
    rng = random.Random(seed)
    result: list[HardCase] = []
    labels = sorted(grouped)
    for index in range(limit):
        label = labels[index % len(labels)]
        positive_pool = grouped[label]
        if len(positive_pool) < 2: continue
        left, right = rng.sample(positive_pool, 2)
        result.append(HardCase(
            f"20ng-pos-{index}", f"doc-{index}-a.txt", left, f"doc-{index}-b.txt", right,
            True, None, "same public benchmark class", "20 Newsgroups via scikit-learn",
        ))
        negative_label = labels[(labels.index(label) + 1) % len(labels)]
        result.append(HardCase(
            f"20ng-neg-{index}", f"doc-{index}-a.txt", left, f"doc-{index}-hard-negative.txt",
            rng.choice(grouped[negative_label]), False, None,
            "nearby public benchmark category", "20 Newsgroups via scikit-learn",
        ))
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("Training/generated/savepilot-hard-cases-v1.jsonl"))
    parser.add_argument("--with-20-newsgroups", type=int, default=0, metavar="PAIRS")
    parser.add_argument("--seed", type=int, default=20261016)
    args = parser.parse_args()
    cases = built_in_cases()
    if args.with_20_newsgroups:
        cases.extend(newsgroups_cases(args.with_20_newsgroups, args.seed))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(json.dumps(asdict(case), ensure_ascii=False) for case in cases) + "\n", encoding="utf-8")
    print(f"generated {len(cases)} hard cases at {args.output}")


if __name__ == "__main__":
    main()
