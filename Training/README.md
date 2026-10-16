# Boundary-focused evaluation and adaptation

SavePilot evaluates relationships between files, not only file-to-folder labels. The deterministic generator emphasizes difficult boundaries: shared author names across unrelated projects, broad finance overlap, polysemy, entity ambiguity, misplaced child folders, and differently worded files from the same course project.

```bash
PYTHONPATH=CrossPlatform/src python3 Training/hard_case_corpus.py
PYTHONPATH=CrossPlatform/src python3 Training/evaluate_hard_cases.py Training/generated/savepilot-hard-cases-v1.jsonl
```

For a larger public-data stress set, install scikit-learn and add `--with-20-newsgroups 100`. The adapter removes headers, footers, and quoted replies, then generates same-class positives and adjacent-category hard negatives. Downloaded benchmark text remains under the ignored `Training/generated/` directory and is not redistributed by SavePilot.

This corpus is an evaluation and hard-negative mining input, not a claim that public newsgroup labels equal a person's folder taxonomy. Production thresholds should be selected on private, user-approved outcomes, with public data used only to expose brittle similarity rules.
