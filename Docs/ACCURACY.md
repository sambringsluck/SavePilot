# Accuracy architecture

SavePilot treats a directory as a mutable label rather than ground truth. Its decision graph contains files whether they are already organized or still loose, folder-purpose nodes, positive same-project edges, and negative or blocked edges learned from corrections and hard cases.

## Delivered decision stack

1. Extract text, OCR, OpenXML structure, entities, metadata, and filenames.
2. Build bounded majority-theme profiles for existing folders and preserve per-file hyperedges.
3. Compare loose and queued files directly. A structured two-file signature may form a project; generic similarity needs a component of at least three files.
4. Compare child-folder content with the declared intent of its parent, so a code-heavy economics corpus cannot hide under a language folder merely because both contain scripts and JSON.
5. Fuse sparse content retrieval, path evidence, file-level relationships, folder coherence, personal confirmations, and explicit negative feedback.
6. Abstain when absolute evidence or the winner margin is weak. Never move without confirmation.

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

Provider quality must be measured against the private golden set and hard-case corpus before it receives nonzero decision weight. A better public leaderboard score is not sufficient.
