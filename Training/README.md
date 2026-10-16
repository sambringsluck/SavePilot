# Boundary-focused evaluation and adaptation

SavePilot evaluates relationships between files, not only file-to-folder labels. The deterministic generator emphasizes difficult boundaries: shared author names across unrelated projects, broad finance overlap, polysemy, entity ambiguity, misplaced child folders, and differently worded files from the same course project.

```bash
PYTHONPATH=CrossPlatform/src python3 Training/hard_case_corpus.py
PYTHONPATH=CrossPlatform/src python3 Training/evaluate_hard_cases.py Training/generated/savepilot-hard-cases-v2.jsonl
PYTHONPATH=CrossPlatform/src python3 Training/train_embedding_relation.py Training/generated/savepilot-hard-cases-v2.jsonl
```

The generator creates three disjoint views: `train` is the only split used to fit the relationship threshold, `development` (`V_dev`) is used to select error-directed Oracle augmentation, and `rule_holdout` (`T_rule`) is monitoring-only. Known personal examples are regression cases, not an untouched `T_real`; SavePilot deliberately reports `T_real` as unavailable until future unseen files have user-confirmed labels.

`train_embedding_relation.py` keeps the embedding foundation model frozen and trains only SavePilot's conservative relationship decision threshold. It does not upload document text; Ollama runs locally. The synthetic corpus is an evaluation and hard-negative-mining input, not a claim that Oracle labels equal a person's folder taxonomy. Production calibration should ultimately be checked once against a private, user-approved, never-before-seen `T_real` set.

Optionally add a public semantic stress set with `--with-20-newsgroups 120`. These cases use the dedicated `public_stress` split because a newsgroup category is not trustworthy ground truth for a person's folder relationship; they are reported as robustness probes and never steer threshold fitting or Oracle augmentation.
