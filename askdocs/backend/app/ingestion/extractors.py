"""Text extraction from uploaded files.

Returns pages as (page_number, text) with 1-based page numbers so citations can
point at a real page. DOCX has no intrinsic pagination, so its whole body is
page 1 (documented limitation).
"""

from __future__ import annotations

import io

from app.errors import ApiError

SUPPORTED = ("txt", "pdf", "docx")


def detect_type(file_name: str) -> str:
    ext = file_name.rsplit(".", 1)[-1].lower() if "." in file_name else ""
    if ext not in SUPPORTED:
        raise ApiError.bad_request(
            "unsupported_file_type",
            f"Only {', '.join(SUPPORTED)} files are supported; got '{ext or file_name}'.",
        )
    return ext


def extract_pages(file_name: str, data: bytes) -> list[tuple[int, str]]:
    doc_type = detect_type(file_name)
    if doc_type == "txt":
        return _extract_txt(data)
    if doc_type == "pdf":
        return _extract_pdf(data)
    return _extract_docx(data)


def _extract_txt(data: bytes) -> list[tuple[int, str]]:
    text = data.decode("utf-8", errors="replace")
    return [(1, text)] if text.strip() else []


def _extract_pdf(data: bytes) -> list[tuple[int, str]]:
    from pypdf import PdfReader

    try:
        reader = PdfReader(io.BytesIO(data))
    except Exception as exc:  # pypdf raises many types; surface one clear error
        raise ApiError.bad_request("pdf_parse_failed", f"Could not read PDF: {exc}") from exc
    pages: list[tuple[int, str]] = []
    for i, page in enumerate(reader.pages, start=1):
        text = (page.extract_text() or "").strip()
        if text:
            pages.append((i, text))
    return pages


def _extract_docx(data: bytes) -> list[tuple[int, str]]:
    from docx import Document

    try:
        document = Document(io.BytesIO(data))
    except Exception as exc:
        raise ApiError.bad_request("docx_parse_failed", f"Could not read DOCX: {exc}") from exc
    parts = [p.text for p in document.paragraphs if p.text.strip()]
    for table in document.tables:  # include table cell text
        for row in table.rows:
            for cell in row.cells:
                if cell.text.strip():
                    parts.append(cell.text.strip())
    body = "\n".join(parts)
    return [(1, body)] if body.strip() else []
