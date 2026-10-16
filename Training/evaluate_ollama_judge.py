#!/usr/bin/env python3
"""Evaluate a bounded local-LLM judge on ambiguous relationship edges.

The fitted embedding decision layer remains the fast path. Only probabilities
inside a predeclared ambiguity band are sent to qwen3, and reverse-order pairs
share a cached decision. T_rule is monitoring-only and T_real is never read.
"""

from __future__ import annotations

import argparse
import json
import urllib.request
from collections import defaultdict
from pathlib import Path

from train_embedding_relation import VectorCache, probability


def metrics(rows: list[dict], predictions: list[bool]) -> dict:
    tp = fp = fn = tn = 0
    for row, predicted in zip(rows, predictions):
        expected = bool(row["should_link"])
        if predicted and expected: tp += 1
        elif predicted: fp += 1
        elif expected: fn += 1
        else: tn += 1
    precision = tp / max(1, tp + fp)
    recall = tp / max(1, tp + fn)
    return {
        "precision": precision, "recall": recall,
        "f1": 2 * precision * recall / max(1e-12, precision + recall),
        "accuracy": (tp + tn) / max(1, len(rows)),
        "tp": tp, "fp": fp, "fn": fn, "tn": tn,
    }


def canonical_key(row: dict) -> str:
    pair = sorted((row["left_text"].strip(), row["right_text"].strip()))
    return "judge-v2\n" + "\n---PAIR---\n".join(pair)


def judge(row: dict, model: str) -> dict:
    prompt = f"""This is a filing decision, not a duplicate-document test.
Files may belong together when they are different assignments, notes, reviews,
or language versions from the same concrete course, research project, or narrow
subject. They do not need identical titles or wording.

Positive example: "AP Physics mechanics homework" and "Newton force, energy,
momentum review" belong in one physics-mechanics course folder.
Positive example: "misinformation repetition study" and "illusory truth effect,
memory and credibility" belong in one misinformation research folder.
Negative example: "Apple quarterly revenue" and "apple pie recipe" only share
an ambiguous word and must not be linked.
Negative example: "mathematical proof" and "legal proof" must not be linked.

File A: {row['left_name']}
Content A: {row['left_text'][:6000]}

File B: {row['right_name']}
Content B: {row['right_text'][:6000]}

Should these files be linked into the same specific project/course/narrow-topic folder?
Shared broad categories, author names, file formats, export boilerplate, or an
ambiguous word are insufficient. Return a conservative decision."""
    payload = {
        "model": model, "stream": False, "think": False,
        "format": {
            "type": "object",
            "properties": {
                "same_folder": {"type": "boolean"},
                "confidence": {"type": "number"},
                "reason": {"type": "string"},
            },
            "required": ["same_folder", "confidence", "reason"],
        },
        "options": {"temperature": 0, "num_predict": 240},
        "messages": [
            {"role": "system", "content": "You are a file-organization relationship judge, not a duplicate detector. Group different materials from one concrete course, research project, or narrow subject; reject broad-category and polysemy collisions. Return JSON only and keep reason under 20 words."},
            {"role": "user", "content": prompt},
        ],
    }
    request = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        outer = json.load(response)
    return json.loads(outer["message"]["content"])


def fmt(value: dict) -> str:
    return f"P={value['precision']:.3f} R={value['recall']:.3f} F1={value['f1']:.3f} Acc={value['accuracy']:.3f}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("corpus", type=Path)
    parser.add_argument("calibration", type=Path)
    parser.add_argument("--model", default="qwen3:4b")
    parser.add_argument("--low", type=float, default=.40)
    parser.add_argument("--high", type=float, default=.75)
    parser.add_argument("--minimum-confidence", type=float, default=.70)
    parser.add_argument("--cache", type=Path, default=Path("Training/generated/ollama-judge-cache.json"))
    args = parser.parse_args()

    rows = [json.loads(line) for line in args.corpus.read_text(encoding="utf-8").splitlines() if line.strip()]
    calibration = json.loads(args.calibration.read_text(encoding="utf-8"))
    # The final round is evaluated here exactly as exported; T_rule does not
    # influence weights, band, confidence gate, or prompts.
    checkpoint = calibration["rounds"][-1]
    vectors = VectorCache(calibration["model"])
    vectors.ensure(rows)
    cache = json.loads(args.cache.read_text()) if args.cache.exists() else {}
    report = {}

    for split in ("development", "rule_holdout"):
        selected = [row for row in rows if row.get("split") == split]
        base_predictions = []
        hybrid_predictions = []
        calls = 0
        groups = defaultdict(list)
        for row in selected:
            score = probability(row, vectors, checkpoint["weights"])
            base = score >= checkpoint["threshold"]
            predicted = base
            if args.low <= score <= args.high:
                key = canonical_key(row)
                if key not in cache:
                    cache[key] = judge(row, args.model)
                    args.cache.parent.mkdir(parents=True, exist_ok=True)
                    args.cache.write_text(json.dumps(cache, ensure_ascii=False, indent=2) + "\n")
                    calls += 1
                    print(f"{split}: local judge {calls} new / {len(cache)} cached")
                decision = cache[key]
                if float(decision.get("confidence", 0)) >= args.minimum_confidence:
                    predicted = bool(decision.get("same_folder"))
            base_predictions.append(base)
            hybrid_predictions.append(predicted)
            groups[row["confusion"]].append(predicted == bool(row["should_link"]))
        base_value = metrics(selected, base_predictions)
        hybrid_value = metrics(selected, hybrid_predictions)
        report[split] = {
            "base": base_value, "hybrid": hybrid_value,
            "subgroups": {name: sum(values) / len(values) for name, values in groups.items()},
            "new_model_calls": calls,
        }
        print(f"\n{split} base:   {fmt(base_value)}")
        print(f"{split} hybrid: {fmt(hybrid_value)}")
        print("worst subgroups:", sorted(report[split]["subgroups"].items(), key=lambda item: item[1])[:8])

    report["configuration"] = {
        "judge_model": args.model, "ambiguity_band": [args.low, args.high],
        "minimum_confidence": args.minimum_confidence,
        "T_real": "not evaluated",
    }
    output = args.calibration.with_name("relationship-hybrid-evaluation.json")
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"\nreport: {output}")


if __name__ == "__main__":
    main()
