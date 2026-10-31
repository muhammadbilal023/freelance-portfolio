# ---- build stage: resolve wheels into an isolated prefix ----
FROM python:3.11-slim AS builder
WORKDIR /app
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY requirements.txt ./
# sqlite-vec ships manylinux wheels, so ANN search is available on Linux images.
RUN pip install --prefix=/install -r requirements.txt

# ---- runtime stage: slim, unprivileged, no build toolchain ----
FROM python:3.11-slim AS runtime
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
# 10001 is a non-system uid with no host collision; SQLite + logs write under /app/data.
RUN useradd -m -u 10001 askdocs
COPY --from=builder /install /usr/local
COPY app ./app
COPY admin ./admin
COPY seed ./seed
RUN mkdir -p /app/data && chown -R askdocs:askdocs /app
USER askdocs

EXPOSE 8090
# Health uses the stdlib (no curl/wget in the slim image); the lazy ASGI `app`
# attribute starts the job runner on boot.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8090/health').status==200 else 1)"

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8090"]
