# Dockerfile
# Base: Python + Lua 5.1
# Hospedagem recomendada: Render.com (Background Worker, free tier)

FROM python:3.11-slim

# ── dependências de sistema ────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
      lua5.1 \
      luarocks \
      git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── dependências Python ────────────────────────────────────────────────────────
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── código do projeto ──────────────────────────────────────────────────────────
COPY . .

# Prometheus parser (dependência Lua) — clona se não existir
RUN if [ ! -d "Prometheus" ]; then \
      git clone --depth=1 https://github.com/prometheus-lua/Prometheus.git Prometheus; \
    fi

# Ajusta permissões
RUN chmod -R 755 deob/

# ── variáveis de ambiente esperadas ───────────────────────────────────────────
# DISCORD_TOKEN  — obrigatória (definida no painel do Render)
# LUA_BIN        — padrão: lua5.1
# CLI_PATH       — padrão: ./deob/cli.lua
# MAX_FILE_KB    — padrão: 512
# DEOB_TIMEOUT   — padrão: 60
# GUILD_IDS      — opcional: "123,456" para sync rápido

ENV LUA_BIN=lua5.1
ENV CLI_PATH=./deob/cli.lua
ENV MAX_FILE_KB=512
ENV DEOB_TIMEOUT=60

# ── entrypoint ────────────────────────────────────────────────────────────────
CMD ["python", "-u", "bot.py"]
