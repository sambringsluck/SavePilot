#!/usr/bin/env python3
"""Iteratively distill an Oracle-labelled embedding relationship decision layer.

The embedding model stays frozen. SavePilot trains a conservative threshold on
`train`, uses only `development` errors to create new training variants, and
monitors `rule_holdout` without using it to steer iteration. Known personal
files are excluded from any claimed T_real score.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

from savepilot.core import document_relationship


def ollama_embed(texts: list[str], model: str, batch_size: int = 32) -> list[list[float]]:
    result: list[list[float]] = []
    for start in range(0, len(texts), batch_size):
        payload = json.dumps({"model": model, "input": texts[start:start + batch_size], "truncate": True}).encode()
        request = urllib.request.Request(
            "http://127.0.0.1:11434/api/embed", data=payload,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(request, timeout=240) as response:
            result.extend(json.load(response)["embeddings"])
        print(f"embedding: {min(start + batch_size, len(texts))}/{len(texts)}")
    return result


def cosine(left: list[float], right: list[float]) -> float:
    dot = sum(a * b for a, b in zip(left, right))
    ln = math.sqrt(sum(a * a for a in left)) or 1
    rn = math.sqrt(sum(b * b for b in right)) or 1
    return dot / (ln * rn)


def pair_text(name: str, text: str) -> str:
    return f"file: {name}\ncontent: {text}"


class VectorCache:
    def __init__(self, model: str):
        self.model = model
        self.values: dict[str, list[float]] = {}

    def ensure(self, rows: list[dict]) -> None:
        ordered: list[str] = []
        seen: set[str] = set()
        for row in rows:
            for value in (pair_text(row["left_name"], row["left_text"]), pair_text(row["right_name"], row["right_text"])):
                if value not in self.values and value not in seen:
                    seen.add(value)
                    ordered.append(value)
        if ordered:
            self.values.update(zip(ordered, ollama_embed(ordered, self.model)))

    def similarity(self, row: dict) -> float:
        return cosine(
            self.values[pair_text(row["left_name"], row["left_text"])],
            self.values[pair_text(row["right_name"], row["right_text"])],
        )


def named_relation(row: dict) -> bool:
    relation = document_relationship(row["left_name"], row["left_text"], row["right_name"], row["right_text"])
    return relation is not None and relation.topic_name is not None


def evaluate(rows: list[dict], cache: VectorCache, threshold: float) -> tuple[dict, list[dict], dict[str, dict]]:
    tp = fp = fn = tn = 0
    errors: list[dict] = []
    groups: dict[str, list[tuple[bool, bool]]] = defaultdict(list)
    for row in rows:
        predicted = named_relation(row) or cache.similarity(row) >= threshold
        expected = bool(row["should_link"])
        groups[row["confusion"]].append((predicted, expected))
        if predicted and expected: tp += 1
        elif predicted: fp += 1
        elif expected: fn += 1
        else: tn += 1
        if predicted != expected:
            errors.append({**row, "predicted": predicted, "similarity": cache.similarity(row)})
    precision = tp / max(1, tp + fp)
    recall = tp / max(1, tp + fn)
    metrics = {
        "precision": precision, "recall": recall,
        "f1": 2 * precision * recall / max(1e-12, precision + recall),
        "accuracy": (tp + tn) / max(1, tp + fp + fn + tn),
        "tp": tp, "fp": fp, "fn": fn, "tn": tn,
    }
    subgroup = {}
    for name, values in groups.items():
        subgroup[name] = {"n": len(values), "accuracy": sum(a == b for a, b in values) / len(values)}
    return metrics, errors, subgroup


def fit_threshold(train: list[dict], cache: VectorCache, minimum_precision: float) -> tuple[float, dict]:
    candidates = []
    for step in range(400, 971):
        threshold = step / 1000
        value, _, _ = evaluate(train, cache, threshold)
        if value["precision"] >= minimum_precision:
            candidates.append((value["f1"], value["accuracy"], threshold, value))
    if not candidates:
        raise RuntimeError("no threshold satisfies the precision floor")
    _, _, threshold, metrics = max(candidates)
    return threshold, metrics


def contradiction_count(rows: list[dict]) -> int:
    labels: dict[str, set[bool]] = defaultdict(set)
    for row in rows:
        left = re.sub(r"\s+", " ", row["left_text"].casefold()).strip()
        right = re.sub(r"\s+", " ", row["right_text"].casefold()).strip()
        labels["||".join(sorted((left, right)))].add(bool(row["should_link"]))
    return sum(len(value) > 1 for value in labels.values())


def augment_from_dev(errors: list[dict], round_index: int, train_counts: Counter) -> tuple[list[dict], dict[str, int]]:
    additions: list[dict] = []
    reasons: Counter[str] = Counter()
    for index, row in enumerate(errors):
        category = "c" if train_counts[row["confusion"]] < 8 else "a"
        shared_noise = " exported archive page footer " if not row["should_link"] else " course project reference "
        variants = [
            (
                f"oracle-r{round_index}-{index}-a{Path(row['left_name']).suffix or '.txt'}",
                row["left_text"] + shared_noise + "alpha",
                f"oracle-r{round_index}-{index}-b{Path(row['right_name']).suffix or '.txt'}",
                row["right_text"] + shared_noise + "beta",
            ),
            (
                f"scan-r{round_index}-{index}-1.txt", " \n ".join(row["left_text"].split()),
                f"scan-r{round_index}-{index}-2.txt", " \n ".join(row["right_text"].split()),
            ),
        ]
        for variant_index, (left_name, left_text, right_name, right_text) in enumerate(variants):
            additions.append({
                **row, "case_id": f"augment-r{round_index}-{index}-{variant_index}",
                "left_name": left_name, "left_text": left_text,
                "right_name": right_name, "right_text": right_text,
                "split": "train", "source": "V_dev error-directed Oracle augmentation",
            })
        reasons[f"{category}:{row['confusion']}"] += len(variants)
    return additions, dict(reasons)


def fmt(value: dict) -> str:
    return f"P={value['precision']:.3f} R={value['recall']:.3f} F1={value['f1']:.3f} Acc={value['accuracy']:.3f}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--model", default="qwen3-embedding:4b")
    parser.add_argument("--minimum-precision", type=float, default=.97)
    parser.add_argument("--max-rounds", type=int, default=8)
    parser.add_argument("--plateau-rounds", type=int, default=3)
    parser.add_argument("--minimum-improvement", type=float, default=.002)
    parser.add_argument("--output", type=Path, default=Path("Training/generated/relationship-embedding-calibration.json"))
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.corpus.read_text(encoding="utf-8").splitlines() if line.strip()]
    train = [row for row in rows if row.get("split") == "train"]
    development = [row for row in rows if row.get("split") == "development"]
    rule_holdout = [row for row in rows if row.get("split") == "rule_holdout"]
    public_stress = [row for row in rows if row.get("split") == "public_stress"]
    if not train or not development or not rule_holdout:
        raise SystemExit("corpus must contain train, development and rule_holdout splits")
    cache = VectorCache(args.model)
    cache.ensure(rows)
    history = []
    best_f1 = -1.0
    plateau = 0
    stop_reason = "达到最大迭代轮数"
    dev_positive_rate = sum(row["should_link"] for row in development) / len(development)

    for round_index in range(1, args.max_rounds + 1):
        threshold, train_metrics = fit_threshold(train, cache, args.minimum_precision)
        dev_metrics, dev_errors, dev_groups = evaluate(development, cache, threshold)
        rule_metrics, _, rule_groups = evaluate(rule_holdout, cache, threshold)
        public_metrics, _, public_groups = evaluate(public_stress, cache, threshold) if public_stress else ({}, [], {})
        contradictions = contradiction_count(train + development)
        train_counts = Counter(row["confusion"] for row in train)
        a_count = sum(train_counts[row["confusion"]] >= 8 for row in dev_errors)
        c_count = len(dev_errors) - a_count
        additions, reasons = augment_from_dev(dev_errors, round_index, train_counts)
        train_positive_rate = sum(row["should_link"] for row in train) / len(train)
        drift = abs(train_positive_rate - dev_positive_rate)
        improvement = dev_metrics["f1"] - best_f1 if best_f1 >= 0 else dev_metrics["f1"]
        plateau = plateau + 1 if best_f1 >= 0 and improvement < args.minimum_improvement else 0
        best_f1 = max(best_f1, dev_metrics["f1"])
        history.append({
            "round": round_index, "threshold": threshold, "train_size": len(train),
            "train": train_metrics, "development": dev_metrics, "rule_holdout": rule_metrics,
            "public_stress": public_metrics,
            "errors": {"a": a_count, "b": contradictions, "c": c_count},
            "added": len(additions), "addition_reasons": reasons, "distribution_drift": drift,
            "development_subgroups": dev_groups, "rule_subgroups": rule_groups,
            "public_subgroups": public_groups,
            "typical_errors": [{k: row[k] for k in ("case_id", "confusion", "should_link", "predicted", "similarity")} for row in dev_errors[:8]],
        })
        print(f"\n轮次：{round_index}")
        print(f"训练集规模：{len(train)}")
        print(f"训练指标：{fmt(train_metrics)}")
        print(f"V_dev 指标：{fmt(dev_metrics)}")
        print(f"T_rule 指标：{fmt(rule_metrics)}")
        if public_metrics:
            print(f"Public stress（只监控）：{fmt(public_metrics)}")
        print(
            "V_dev 混淆矩阵："
            f"TP={dev_metrics['tp']} FP={dev_metrics['fp']} "
            f"FN={dev_metrics['fn']} TN={dev_metrics['tn']}"
        )
        worst_groups = sorted(dev_groups.items(), key=lambda item: item[1]["accuracy"])[:6]
        print("V_dev 子群体：" + json.dumps(dict(worst_groups), ensure_ascii=False))
        print(f"错误分类统计：a={a_count}, b={contradictions}, c={c_count}")
        print(f"本轮补样本：{len(additions)}；依据={json.dumps(reasons, ensure_ascii=False)}")
        print(f"规则矛盾报告：{'无' if contradictions == 0 else f'{contradictions} 组冲突'}")
        print(f"与上轮对比：F1 变化={improvement:+.4f}；分布偏移={drift:.3f}")
        if contradictions / max(1, len(train) + len(development)) > .05:
            stop_reason = "规则矛盾占比超过 5%"; break
        if drift > .20:
            stop_reason = "训练集与开发集正负分布偏离超过 20%"; break
        if plateau >= args.plateau_rounds and dev_metrics["precision"] >= args.minimum_precision:
            stop_reason = f"V_dev 连续 {args.plateau_rounds} 轮提升不足 {args.minimum_improvement:.3f}，且精确率门槛已满足"
            break
        train.extend(additions)
        cache.ensure(additions)

    final = history[-1]
    payload = {
        "model": args.model, "threshold": final["threshold"],
        "minimum_precision": args.minimum_precision, "stop_reason": stop_reason,
        "rounds": history,
        "T_real": {"status": "not_available", "reason": "已知个人文件只作回归，不冒充未见真实测试集"},
        "conclusion": "本轮训练的是 Oracle 规则蒸馏的关系判定层；尚不能声称拟合真实个人分布。",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"\n停止原因：{stop_reason}")
    print("T_real：未评估（尚无合法的全程未见真实集）")
    if final["development"]["precision"] < args.minimum_precision or final["rule_holdout"]["precision"] < .95:
        raise SystemExit("precision gate failed")


if __name__ == "__main__":
    main()
