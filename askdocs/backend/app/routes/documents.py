"""Document upload/list/delete endpoints (the RAG ingestion surface)."""

from __future__ import annotations

import threading

from fastapi import APIRouter, File, Request, UploadFile
from fastapi.concurrency import run_in_threadpool

from app.deps import get_container
from app.errors import ApiError
from app.ingestion.pipeline import delete_document, ingest_document

router = APIRouter(prefix="/documents", tags=["documents"])

# One shared SQLite connection is not safe for concurrent writers; uploads are
# infrequent so serializing them is the cheapest correct fix.
_write_lock = threading.Lock()


@router.post("/upload", status_code=201)
async def upload_document(request: Request, file: UploadFile = File(...)) -> dict[str, object]:
    c = get_container(request)
    data = await file.read()
    if not data:
        raise ApiError.bad_request("empty_file", "Uploaded file is empty.")
    file_name = file.filename or "upload.txt"

    def _run() -> dict[str, object]:
        with _write_lock:
            return ingest_document(
                documents=c.documents,
                chunks=c.chunks,
                vectors=c.vectors,
                embedder=c.embedder,
                file_name=file_name,
                data=data,
            )

    summary = await run_in_threadpool(_run)
    c.logger.info(
        "document ingested",
        extra={"extras": {"doc_id": summary["id"], "chunks": summary["num_chunks"]}},
    )
    return summary


@router.get("")
async def list_documents(request: Request) -> dict[str, object]:
    c = get_container(request)
    docs = [
        {
            "id": d.id,
            "file_name": d.file_name,
            "doc_type": d.doc_type,
            "num_pages": d.num_pages,
            "num_chunks": d.num_chunks,
            "created_at": d.created_at,
        }
        for d in c.documents.list_all()
    ]
    return {"documents": docs, "count": len(docs)}


@router.delete("/{doc_id}", status_code=204)
async def remove_document(request: Request, doc_id: int) -> None:
    c = get_container(request)

    def _run() -> bool:
        with _write_lock:
            return delete_document(documents=c.documents, vectors=c.vectors, doc_id=doc_id)

    removed = await run_in_threadpool(_run)
    if not removed:
        raise ApiError.not_found("Document")
