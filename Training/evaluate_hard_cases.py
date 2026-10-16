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
    rows = [json.loads(line) for line in args.corpus.read_text(encoding="utf-8").splitlines() if line.strip()]
    failures: list[str] = []
    for row in rows:
        relation = document_relationship(row["left_name"], row["left_text"], row["right_name"], row["right_text"])
        predicted = relation is not None and (relation.topic_name is not None or relation.score >= .34)
        topic_ok = not row["expected_topic"] or (relation and relation.topic_name == row["expected_topic"])
        if predicted != row["should_link"] or not topic_ok:
            failures.append(row["case_id"])
    accuracy = (len(rows) - len(failures)) / max(1, len(rows))
    print(f"hard-case relationship accuracy={accuracy:.3f} n={len(rows)} failures={','.join(failures) or 'none'}")
    if accuracy < args.minimum_accuracy:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
