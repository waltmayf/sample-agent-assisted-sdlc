FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ARG UV_DEFAULT_INDEX
ARG UV_INDEX

WORKDIR /app

ENV UV_SYSTEM_PYTHON=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_NO_PROGRESS=1 \
    PYTHONUNBUFFERED=1 \
    DOCKER_CONTAINER=1 \
    UV_DEFAULT_INDEX=${UV_DEFAULT_INDEX} \
    UV_INDEX=${UV_INDEX} \
    PATH="/app/.venv/bin:/home/bedrock_agentcore/.local/bin:$PATH" \
    CLAUDE_CODE_USE_BEDROCK=1 \
    CLAUDE_CODE_ENABLE_TELEMETRY=1 \
    CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 \
    OTEL_LOG_TOOL_DETAILS=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates bash nodejs npm openssh-client jq \
 && rm -rf /var/lib/apt/lists/*

# OpenTelemetry Collector Contrib — includes sigv4auth + transform (OTTL)
# processors that ADOT v0.48.0 lacks. Runs as a sidecar inside this container,
# listens on 127.0.0.1:4318, signs OTLP traffic with SigV4, and forwards to
# xray.<region>.amazonaws.com / logs.<region>.amazonaws.com.
ARG OTELCOL_VERSION=0.104.0
RUN curl -fsSL -o /tmp/otelcol-contrib.deb \
      "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_$(dpkg --print-architecture).deb" \
 && dpkg -i /tmp/otelcol-contrib.deb \
 && rm /tmp/otelcol-contrib.deb

RUN useradd -m -u 1000 bedrock_agentcore

# Install Claude Code CLI (download separately for auditability)
USER bedrock_agentcore
RUN curl -fsSL -o /tmp/claude-install.sh https://claude.ai/install.sh && \
    bash /tmp/claude-install.sh && \
    rm /tmp/claude-install.sh
USER root

COPY pyproject.toml ./
RUN uv sync --no-dev --no-install-project

COPY --chown=bedrock_agentcore:bedrock_agentcore . .
RUN uv sync --no-dev

USER bedrock_agentcore

# AgentCore Runtime service contract ports
EXPOSE 8080 8000 9000

CMD ["python", "-m", "main"]
