#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from savepilot.core import document_relationship


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--minimum-accuracy", type=float, default=.90)
    args = parser.parse_args()
    all_rows = [json.loads(line) for line in args.corpus.read_text(encoding="utf-8").splitlines() if line.strip()]
    rows = [row for row in all_rows if not row.get("requires_embedding", False)]
    print(f"lexical/structured baseline cases={len(rows)} embedding-only deferred={len(all_rows) - len(rows)}")
    failed = False
    for split in sorted({row.get("split", "development") for row in rows}):
        selected = [row for row in rows if row.get("split", "development") == split]
        failures: list[str] = []
        true_positive = false_positive = false_negative = 0
        for row in selected:
            relation = document_relationship(row["left_name"], row["left_text"], row["right_name"], row["right_text"])
            predicted = relation is not None and (relation.topic_name is not None or relation.score >= .34)
            topic_ok = not row["expected_topic"] or (relation and relation.topic_name == row["expected_topic"])
            if predicted and row["should_link"] and topic_ok: true_positive += 1
            elif predicted and (not row["should_link"] or not topic_ok): false_positive += 1
            elif not predicted and row["should_link"]: false_negative += 1
            if predicted != row["should_link"] or not topic_ok: failures.append(row["case_id"])
        accuracy = (len(selected) - len(failures)) / max(1, len(selected))
        precision = true_positive / max(1, true_positive + false_positive)
        recall = true_positive / max(1, true_positive + false_negative)
        print(f"{split}: accuracy={accuracy:.3f} precision={precision:.3f} recall={recall:.3f} n={len(selected)} failures={','.join(failures[:12]) or 'none'}")
        if accuracy < args.minimum_accuracy or precision < .95: failed = True
    if failed: raise SystemExit(1)


if __name__ == "__main__":
    main()
