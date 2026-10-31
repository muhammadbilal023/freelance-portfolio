#!/usr/bin/env python3
"""AskDocs evaluation harness.

Runs the 10 questions in `eval/questions.jsonl` and reports answer accuracy,
token usage, and estimated cost.

Two modes:
  * in-process (default) - no API keys. Ingests the seeded sample docs into an
    in-memory store and grades RETRIEVAL + grounding using an extractive oracle
    (the top-scoring chunk stands in for a perfectly-grounded answer). This is
    deterministic and CI-friendly; it validates the pipeline and the metrics.
  * live (-u/--base-url) - posts each question to a running AskDocs server
    (`python -m app.run`) that has real provider + embedding keys configured,
    and grades the returned answer + citations.

Estimated cost uses per-1k-token prices from the environment:
  EVAL_PRICE_IN_PER_1K, EVAL_PRICE_OUT_PER_1K (USD; default 0 => cost shown as n/a).

Usage:
  python scripts/evaluate.py                 # in-process, fake embeddings
  python scripts/evaluate.py -u http://localhost:8090
  python scripts/evaluate.py --out eval/results.md
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

# Make `import app...` work whether run as a script or via -m.
BACKEND_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_ROOT))

SAMPLE_DOCS_DIR = BACKEND_ROOT / "seed" / "sample_docs"
DEFAULT_QUESTIONS = BACKEND_ROOT / "eval" / "questions.jsonl"
FALLBACK_ANSWER = "I don't know."


@dataclass
class Question:
    question: str
    expected_file: str
    expected_keywords: list[str]

    def keyword_hit(self, text: str) -> bool:
        lowered = text.lower()
        return any(k.lower() in lowered for k in self.expected_keywords)


@dataclass
class Result:
    question: str
    expected_file: str
    cited_file: str
    answer: str
    correct: bool
    prompt_tokens: int
    completion_tokens: int


def load_questions(path: Path) -> list[Question]:
    questions: list[Question] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        questions.append(
            Question(
                question=obj["question"],
                expected_file=obj["expected_file"],
                expected_keywords=list(obj["expected_keywords"]),
            )
        )
    return questions


def _approx_tokens(text: str) -> int:
    from app.llm.base import approx_tokens

    return approx_tokens(text)


# ----------------------------- in-process mode ------------------------------


def run_inprocess(questions: list[Question], top_k: int) -> list[Result]:
    from app.config import Settings
    from app.db.database import open_database
    from app.db.repositories import (
        ChunksRepository,
        DocumentsRepository,
        VectorStore,
    )
    from app.ingestion.pipeline import ingest_document
    from app.llm.fake import FakeLLM
    from app.rag.retriever import retrieve

    settings = Settings(database_path=":memory:", llm_provider="fake", log_level="ERROR")
    conn, vec_available = open_database(":memory:", settings.embedding_dimensions)
    documents = DocumentsRepository(conn)
    chunks = ChunksRepository(conn)
    vectors = VectorStore(conn, vec_available=vec_available)
    embedder = FakeLLM(dimensions=settings.embedding_dimensions)

    for doc in sorted(SAMPLE_DOCS_DIR.glob("*.txt")):
        ingest_document(
            documents=documents,
            chunks=chunks,
            vectors=vectors,
            embedder=embedder,
            file_name=doc.name,
            data=doc.read_bytes(),
        )

    results: list[Result] = []
    for q in questions:
        hits = retrieve(
            vectors=vectors,
            documents=documents,
            embedder=embedder,
            query=q.question,
            top_k=top_k,
            min_score=0.0,
            chunks_repo=chunks,
        )
        if hits:
            top = hits[0]
            answer = top.content.strip()[:120]
            cited = top.file_name
            correct = cited == q.expected_file and q.keyword_hit(top.content)
        else:
            answer = FALLBACK_ANSWER
            cited = "-"
            correct = False
        prompt = _approx_tokens(q.question + " " + " ".join(h.content for h in hits))
        results.append(
            Result(
                question=q.question,
                expected_file=q.expected_file,
                cited_file=cited,
                answer=answer,
                correct=correct,
                prompt_tokens=prompt,
                completion_tokens=_approx_tokens(answer),
            )
        )
    return results


# -------------------------------- live mode ---------------------------------


def run_live(base_url: str, user_id: str, questions: list[Question]) -> list[Result]:
    results: list[Result] = []
    for q in questions:
        payload = json.dumps({"question": q.question, "session_id": ""}).encode("utf-8")
        req = urllib.request.Request(
            f"{base_url.rstrip('/')}/chat",
            data=payload,
            headers={"Content-Type": "application/json", "X-User-Id": user_id},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, urllib.error.HTTPError) as exc:
            raise SystemExit(f"Request to {base_url} failed: {exc}") from exc
        answer = body.get("answer", "")
        cited_files = [c.get("file_name", "") for c in body.get("citations", [])]
        cited = cited_files[0] if cited_files else "-"
        correct = q.expected_file in cited_files and q.keyword_hit(answer)
        results.append(
            Result(
                question=q.question,
                expected_file=q.expected_file,
                cited_file=cited,
                answer=answer[:120],
                correct=correct,
                prompt_tokens=_approx_tokens(q.question),
                completion_tokens=_approx_tokens(answer),
            )
        )
    return results


# -------------------------------- reporting ---------------------------------


def render_markdown(results: list[Result], *, mode: str, price_in: float, price_out: float) -> str:
    total = len(results)
    correct = sum(1 for r in results if r.correct)
    acc = 100.0 * correct / total if total else 0.0
    ptokens = sum(r.prompt_tokens for r in results)
    ctokens = sum(r.completion_tokens for r in results)
    cost = ptokens / 1000 * price_in + ctokens / 1000 * price_out
    cost_label = f"${cost:.4f}" if (price_in or price_out) else "n/a"

    lines = [
        "# AskDocs evaluation results",
        "",
        f"- Mode: **{mode}**",
        f"- Questions: **{total}**",
        f"- Accuracy: **{correct}/{total} ({acc:.0f}%)**",
        f"- Prompt tokens (est.): **{ptokens}**",
        f"- Completion tokens (est.): **{ctokens}**",
        f"- Estimated cost: **{cost_label}**",
        "",
        "| # | Question | Expected file | Cited file | Result |",
        "|---|----------|---------------|-----------|--------|",
    ]
    for i, r in enumerate(results, start=1):
        verdict = "✅ correct" if r.correct else "❌ wrong"
        short_q = r.question if len(r.question) <= 52 else r.question[:49] + "…"
        lines.append(f"| {i} | {short_q} | {r.expected_file} | {r.cited_file} | {verdict} |")
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    # Windows consoles default to cp1252; force UTF-8 so the results table prints.
    with contextlib.suppress(AttributeError, ValueError):
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    parser = argparse.ArgumentParser(description="Evaluate AskDocs answer accuracy.")
    parser.add_argument("-u", "--base-url", help="Run against a live server at this URL.")
    parser.add_argument("--user-id", default="eval-bot", help="X-User-Id for live mode.")
    parser.add_argument("--top-k", type=int, default=4, help="Retrieval depth (in-process).")
    parser.add_argument("--questions", type=Path, default=DEFAULT_QUESTIONS)
    parser.add_argument("--out", type=Path, default=BACKEND_ROOT / "eval" / "results.md")
    parser.add_argument(
        "--min-accuracy",
        type=float,
        default=None,
        help="Exit non-zero if accuracy is below this percentage (optional gate).",
    )
    args = parser.parse_args(argv)

    questions = load_questions(args.questions)
    price_in = float(os.getenv("EVAL_PRICE_IN_PER_1K", "0"))
    price_out = float(os.getenv("EVAL_PRICE_OUT_PER_1K", "0"))

    if args.base_url:
        results = run_live(args.base_url, args.user_id, questions)
        mode = f"live HTTP ({args.base_url})"
    else:
        results = run_inprocess(questions, args.top_k)
        mode = "in-process (fake embeddings, extractive oracle)"

    md = render_markdown(results, mode=mode, price_in=price_in, price_out=price_out)
    print(md)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(md, encoding="utf-8")
    print(f"[wrote {args.out}]", file=sys.stderr)

    # Informational by default; only fail the process when a gate was requested.
    if args.min_accuracy is not None:
        accuracy = 100.0 * sum(r.correct for r in results) / len(results)
        return 0 if accuracy >= args.min_accuracy else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
