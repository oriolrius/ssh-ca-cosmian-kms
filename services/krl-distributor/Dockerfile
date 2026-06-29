# syntax=docker/dockerfile:1
#
# KRL Distribution Service — slim image built and run with uv.
#
# The container holds NO secrets. At runtime it needs:
#   * the cosmian CLI on PATH (mount it in, or extend this image to add it)
#   * a Cosmian KMS reachable per ~/.cosmian/cosmian.toml (mount the config)
#
FROM python:3.11-slim

# uv: fast, reproducible Python dependency management.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    PATH="/app/.venv/bin:${PATH}" \
    PORT=8088

WORKDIR /app

# Install dependencies first (better layer caching), then the app.
COPY pyproject.toml README.md ./
RUN uv venv /app/.venv
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --python /app/.venv \
        "fastapi>=0.110" "uvicorn[standard]>=0.29"

COPY app.py ./

# Run as an unprivileged user — the service never touches the host filesystem.
RUN useradd --system --no-create-home --uid 10088 krl \
 && chown -R krl:krl /app
USER krl

EXPOSE 8088

# Stateless liveness check against /healthz (does not touch the KMS).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8088/healthz').status==200 else 1)"

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8088"]
