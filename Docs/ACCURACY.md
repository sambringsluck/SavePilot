# Accuracy architecture

SavePilot treats a directory as a mutable label rather than ground truth. Its decision graph contains files whether they are already organized or still loose, folder-purpose nodes, positive same-project edges, and negative or blocked edges learned from corrections and hard cases.

## Delivered decision stack

1. Extract text, OCR, OpenXML structure, entities, metadata, and filenames.
2. Build bounded majority-theme profiles for existing folders and preserve per-file hyperedges.
3. Compare loose and queued files directly. A structured two-file signature may form a project; generic similarity needs a component of at least three files.
4. Compare child-folder content with the declared intent of its parent, so a code-heavy economics corpus cannot hide under a language folder merely because both contain scripts and JSON.
5. Fuse sparse content retrieval, path evidence, file-level relationships, folder coherence, personal confirmations, and explicit negative feedback.
6. Abstain when absolute evidence or the winner margin is weak. Never move without confirmation.

The graph is deliberately bounded rather than a blind whole-disk crawl. It covers authorized archive roots, Desktop, Downloads, and configured watch roots. Startup pre-reads 160–240 loose files using root-balanced recent and historical sampling so queue order or one recent burst cannot change the first answer; folder nodes use adaptive, time- and format-diverse majority sampling (up to 24 files per folder). System libraries, application bundles, caches, managed media libraries, and build outputs stay outside the graph. Confirmations and corrections update it incrementally.

When a candidate folder's own content matches but its parent purpose conflicts, SavePilot keeps the candidate identity and emits a prerequisite whole-folder relocation proposal. The dependent file displays the folder's planned corrected path and cannot be confirmed until that prerequisite is accepted or rejected. Acceptance synchronizes the actual path, including collision suffixes; rejection sends dependents back to the folder's current path. This avoids rejecting a semantically correct folder or accidentally creating a duplicate destination.

## Boundary corpus

`Training/hard_case_corpus.py` creates deterministic positives and hard negatives, including author-name leakage, historical-data/history ambiguity, legal-force/physics-force polysemy, entity ambiguity, broad-finance collisions, generic filenames, OCR spacing, and exported-chat boilerplate. The optional 20-Newsgroups adapter adds public same-class positives and nearby-category hard negatives without committing downloaded text.

This follows the established hard-negative pattern: select examples that appear close to the anchor but are not valid matches. Sentence Transformers documents both mining and cross-encoder rescoring: <https://www.sbert.net/docs/package_reference/util/hard_negatives.html>.

## API and model strategy

No single model is allowed to decide a move. MTEB covers classification, clustering, reranking, retrieval and other embedding tasks, and reports that no one embedding approach dominates every task: <https://arxiv.org/abs/2210.07316>. BEIR similarly finds BM25 a robust baseline while reranking is often stronger but more expensive: <https://arxiv.org/abs/2104.08663>. SavePilot therefore uses a cascade:

- deterministic extraction and sparse retrieval for recall and explanations;
- local file-relationship and purpose gates for precision;
- optional embeddings to retrieve candidates, never to authorize a move alone;
- optional reranking/LLM judging only for the top ambiguous candidates;
- final margin, consistency, and project-intent gates before showing a recommendation.

The preferred embedding integration is local Ollama `/api/embed`, which returns normalized vectors and supports batching: <https://docs.ollama.com/capabilities/embeddings>. Cloud embeddings or rerank APIs can be provider adapters, but remain opt-in because filenames and document text may be private. Cohere documents query-document reranking at <https://docs.cohere.com/docs/rerank>; OpenAI documents vector embeddings at <https://developers.openai.com/api/docs/guides/embeddings>. Image-only files can later add a local zero-shot vision channel; Hugging Face documents open-label image classification at <https://huggingface.co/docs/transformers/main_classes/pipelines>.

The default high-accuracy local profile uses `qwen3-embedding:4b` for batched candidate retrieval and `qwen3:4b` only for close-candidate review. Sparse retrieval, project/entity anchors, hierarchy conflicts, user feedback, and abstention gates remain authoritative. If Ollama or either model is unavailable, the app degrades safely instead of blocking file saves.

Build 29 applies that cascade in production: embedding retrieves a bounded set of existing folder profiles, each containing majority-theme terms and representative file hyperedges; the local language model then selects one or vetoes the entire set. Its prompt explicitly treats this as a filing decision rather than duplicate detection, so different assignments, notes, reviews, and language versions from one course or project may stay together while same-word/different-meaning cases are rejected.

The v2 Oracle boundary evaluation uses the fast multi-feature relationship layer for clear cases and calls the local judge only inside the fixed 0.40–0.75 ambiguity band. On `V_dev`, the base layer scored P=0.942 / R=0.907 / F1=0.925; the hybrid scored P=1.000 / R=0.944 / F1=0.971. On monitoring-only `T_rule`, the base scored P=1.000 / R=0.852 / F1=0.920 and the hybrid scored P=1.000 / R=0.944 / F1=0.971. An initial overly strict prompt was rejected because it treated same-folder as near-duplicate and lowered recall. `T_real` remains intentionally unevaluated until genuinely unseen, user-confirmed labels exist.

`Training/train_embedding_relation.py` implements the iterative Oracle protocol with disjoint `train`, `V_dev`, and monitoring-only `T_rule` splits. Its lightweight decision layer combines frozen embedding similarity, sparse overlap, filename, length, and structured-relation features before threshold calibration. It enforces a 0.97 precision floor, three-round plateau detection, subgroup metrics, confusion matrices, contradiction checks, class-balanced augmentation, and distribution-drift stops. Public 20-Newsgroups pairs live in a separate monitoring-only `public_stress` split because topic labels from a benchmark are not truthful personal-folder labels. Known user examples remain regression cases; they are never misreported as an untouched `T_real`.

Provider quality must be measured against the private golden set and hard-case corpus before it receives nonzero decision weight. A better public leaderboard score is not sufficient.
