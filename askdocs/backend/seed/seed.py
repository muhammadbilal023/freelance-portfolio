"""Seeds sample documents into the configured database.

Run from the backend directory:   python -m seed.seed
Idempotent by file name - already-ingested samples are skipped. Uses the fake
embedder unless OPENAI_API_KEY is set, so it works with zero credentials.
"""

from __future__ import annotations

from pathlib import Path

from app.config import get_settings
from app.db.database import open_database
from app.db.repositories import ChunksRepository, DocumentsRepository, VectorStore
from app.ingestion.pipeline import ingest_document
from app.logging_setup import setup_logging
from app.main import build_embedder

SAMPLE_DIR = Path(__file__).resolve().parent / "sample_docs"


def main() -> None:
    settings = get_settings()
    logger = setup_logging(settings.log_level, pretty=settings.log_pretty)
    conn, vec_available = open_database(settings.database_path, settings.embedding_dimensions)
    documents = DocumentsRepository(conn)
    existing = {d.file_name for d in documents.list_all()}

    embedder = build_embedder(settings, logger)
    chunks = ChunksRepository(conn)
    vectors = VectorStore(conn, vec_available=vec_available)

    seeded = 0
    for path in sorted(SAMPLE_DIR.glob("*.txt")):
        if path.name in existing:
            logger.info("skip (already present)", extra={"extras": {"file": path.name}})
            continue
        data = path.read_bytes()
        summary = ingest_document(
            documents=documents,
            chunks=chunks,
            vectors=vectors,
            embedder=embedder,
            file_name=path.name,
            data=data,
        )
        logger.info(
            "seeded",
            extra={"extras": {"file": path.name, "chunks": summary["num_chunks"]}},
        )
        seeded += 1
    logger.info(f"seeded {seeded} document(s) into {settings.database_path}")


if __name__ == "__main__":
    main()
