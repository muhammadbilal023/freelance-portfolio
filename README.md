# Freelance Portfolio

A monorepo of production-quality sample projects demonstrating full-stack capabilities for clients.
Each project ships with tests, documentation, containerization and CI — the same standards applied to paid client work.

## Projects

| # | Project | Stack | Client Value | Status |
|---|---------|-------|--------------|--------|
| 1 | [BookEasy](./book-easy) | Flutter · Riverpod · Firebase · Node/TS · Stripe | Lets service businesses (salons, clinics, tutors) take bookings and payments from a single mobile app, cutting no-shows and manual scheduling. | ✅ Complete |
| 2 | [SyncFlow](./syncflow) | Node/TS · Express · SQLite · Stripe/Shopify/Sheets/HubSpot/Airtable/Slack | Automates data movement between the tools a business already uses, with signed webhooks, retries, a dead-letter queue and an audit trail — no per-task SaaS fees. | ✅ Complete |
| 3 | [AskDocs](./askdocs) | Python/FastAPI · RAG (sqlite-vec) · OpenAI/Anthropic · Airtable/Slack handoff | A support bot that answers only from a company's own documents, with citations, "I don't know" fallback, prompt-injection defense and automatic human handoff — deflecting tickets without hallucinating policy. | ✅ Complete |

## Repository Layout

```
freelance-portfolio/
├── .github/workflows/ci.yml   # Lint + test pipeline for all projects
├── book-easy/
│   ├── mobile/                # Flutter app (feature-first architecture)
│   └── backend/               # Payments API (Express + Stripe test mode)
├── syncflow/
│   ├── src/                   # Integration hub (queue, flows, integrations, routes)
│   ├── public/                # Admin dashboard (plain HTML/CSS/JS)
│   └── tests/                 # vitest + supertest, in-memory db, fakes
└── askdocs/
    ├── backend/
    │   ├── app/               # FastAPI (llm, ingestion, rag, guardrails, chat,
    │   │                      #   handoff, queue, db, routes)
    │   ├── admin/             # static chat web UI
    │   ├── tests/             # pytest + FakeLLM (zero API keys)
    │   ├── eval/              # questions.jsonl + results.md
    │   └── Dockerfile / docker-compose.yml / .env.example
    └── mobile/                # bonus Flutter chat screen
```

## Engineering Principles

- **Clean architecture** — features are modular (domain / data / presentation), dependencies point inward.
- **No hardcoded secrets** — every service reads configuration from environment variables; `.env.example` files document required values.
- **Test mode only** — payments use Stripe test keys and sandbox accounts.
- **Verified by CI** — GitHub Actions runs lint and tests on every push and pull request.

## CI Status

The [CI workflow](./.github/workflows/ci.yml) runs per-project jobs (backend lint/tests, Flutter analyze/tests, SyncFlow lint/typecheck/tests, AskDocs `ruff`+`pytest` and its Flutter app) triggered by path filters, so a change in one project doesn't run another's pipeline.

## Getting Started

Pick a project directory and follow its README:

- [BookEasy →](./book-easy/README.md)
- [SyncFlow →](./syncflow/README.md)
- [AskDocs →](./askdocs/README.md)

Each README ends with the client value it delivers and how it could be extended. For a quick walkthrough, see the [Demo Video Checklist](./DEMO_VIDEO_CHECKLIST.md) — a ~3-minute recording script per project.
