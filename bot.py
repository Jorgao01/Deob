"""
bot.py - Discord bot para o Prometheus Deobfuscator
Hospedagem: Render.com (Background Worker, free tier)

Comandos:
  /deob           - Deobfusca um arquivo .lua enviado
  /deob-trace     - Só executa trace dinâmico
  /deob-static    - Só executa steps estáticos (sem trace)
  /deob-help      - Ajuda
"""

import discord
from discord import app_commands
from discord.ext import commands

import os
import asyncio
import subprocess
import tempfile
import shutil
import time
import sys
from pathlib import Path

# ─── configuração ─────────────────────────────────────────────────────────────

BOT_TOKEN    = os.environ.get("DISCORD_TOKEN", "")
LUA_BINARY   = os.environ.get("LUA_BIN", "lua5.1")   # ou "lua"
CLI_PATH     = os.environ.get("CLI_PATH", "./deob/cli.lua")
MAX_FILE_KB  = int(os.environ.get("MAX_FILE_KB", "512"))   # tamanho máximo do input
TIMEOUT_SECS = int(os.environ.get("DEOB_TIMEOUT", "60"))   # timeout total do processo

# IDs de guild(s) autorizadas (deixar vazio para global - demora 1h para propagar)
# Ex: GUILD_IDS = [123456789, 987654321]
GUILD_IDS_STR = os.environ.get("GUILD_IDS", "")
GUILD_IDS = [int(x.strip()) for x in GUILD_IDS_STR.split(",") if x.strip().isdigit()]

# ─── intents ──────────────────────────────────────────────────────────────────

intents = discord.Intents.default()
bot     = commands.Bot(command_prefix="!", intents=intents)
tree    = bot.tree

# ─── helpers ──────────────────────────────────────────────────────────────────

def format_size(n: int) -> str:
    if n < 1024:     return f"{n} B"
    if n < 1048576:  return f"{n/1024:.1f} KB"
    return f"{n/1048576:.1f} MB"


async def download_attachment(attachment: discord.Attachment) -> bytes | None:
    """Baixa o attachment e retorna os bytes, ou None se muito grande."""
    if attachment.size > MAX_FILE_KB * 1024:
        return None
    return await attachment.read()


async def run_deob(
    lua_code: bytes,
    trace: str = "prints",
    static_only: bool = False,
    trace_only: bool = False,
    pretty: bool = True,
    timeout: int = TIMEOUT_SECS,
) -> tuple[str | None, str, float]:
    """
    Executa o deobfuscator em subprocesso isolado.
    Retorna: (código_deobfuscado | None, stderr/log, tempo_gasto)
    """
    tmpdir = tempfile.mkdtemp(prefix="deob_")
    try:
        in_path  = os.path.join(tmpdir, "input.lua")
        out_path = os.path.join(tmpdir, "input.deob.lua")

        with open(in_path, "wb") as f:
            f.write(lua_code)

        cmd = [
            LUA_BINARY, CLI_PATH,
            in_path,
            "--out", out_path,
            "--timeout", str(max(5, timeout - 5)),
        ]

        if pretty:          cmd.append("--pretty")
        if static_only:     cmd.append("--static-only")
        elif trace_only:    cmd.append("--trace-only")

        if not static_only:
            cmd += ["--trace", trace]

        t0 = time.monotonic()
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=os.path.dirname(os.path.abspath(CLI_PATH)) or ".",
            )
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(), timeout=timeout
            )
        except asyncio.TimeoutError:
            proc.kill()
            return None, f"⏱ Timeout após {timeout}s", time.monotonic() - t0

        elapsed = time.monotonic() - t0
        log     = (stdout + stderr).decode("utf-8", errors="replace")

        if not os.path.exists(out_path):
            return None, log or "Sem saída gerada", elapsed

        with open(out_path, "rb") as f:
            result = f.read()

        return result, log, elapsed

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def make_embed(
    title: str,
    description: str = "",
    color: discord.Color = discord.Color.blurple(),
    fields: list[tuple[str, str, bool]] | None = None,
) -> discord.Embed:
    embed = discord.Embed(title=title, description=description, color=color)
    embed.set_footer(text="Prometheus Deobfuscator")
    if fields:
        for name, value, inline in fields:
            embed.add_field(name=name, value=value[:1024], inline=inline)
    return embed


def truncate_log(log: str, max_chars: int = 1500) -> str:
    lines = log.strip().splitlines()
    out   = []
    total = 0
    for line in lines:
        if total + len(line) > max_chars:
            out.append(f"... (+{len(lines)-len(out)} linhas)")
            break
        out.append(line)
        total += len(line) + 1
    return "\n".join(out) or "(sem log)"

# ─── eventos ──────────────────────────────────────────────────────────────────

@bot.event
async def on_ready():
    guilds = [discord.Object(id=g) for g in GUILD_IDS] if GUILD_IDS else None
    if guilds:
        for g in guilds:
            tree.copy_global_to(guild=g)
            await tree.sync(guild=g)
        print(f"[bot] Slash commands sincronizados em {len(guilds)} guild(s)")
    else:
        await tree.sync()
        print("[bot] Slash commands globais sincronizados (pode demorar até 1h)")
    print(f"[bot] Logado como {bot.user} | Lua: {LUA_BINARY} | CLI: {CLI_PATH}")


@bot.event
async def on_error(event, *args, **kwargs):
    import traceback
    print(f"[bot] Erro em {event}:", file=sys.stderr)
    traceback.print_exc()

# ─── /deob ────────────────────────────────────────────────────────────────────

@tree.command(name="deob", description="Deobfusca um arquivo .lua com o Prometheus Deobfuscator")
@app_commands.describe(
    arquivo="Arquivo .lua obfuscado",
    trace="Modo de trace dinâmico (padrão: prints)",
    pretty="Formatar saída com indentação (padrão: sim)",
)
@app_commands.choices(trace=[
    app_commands.Choice(name="prints (só print/io.write)", value="prints"),
    app_commands.Choice(name="api (chamadas de API)",       value="api"),
    app_commands.Choice(name="off (só estático)",           value="off"),
])
async def cmd_deob(
    interaction: discord.Interaction,
    arquivo: discord.Attachment,
    trace: app_commands.Choice[str] = None,
    pretty: bool = True,
):
    await _run_deob_interaction(
        interaction, arquivo,
        trace_level  = trace.value if trace else "prints",
        static_only  = (trace is not None and trace.value == "off"),
        trace_only   = False,
        pretty       = pretty,
        title        = "Deobfuscator Completo",
    )

# ─── /deob-static ─────────────────────────────────────────────────────────────

@tree.command(name="deob-static", description="Só steps estáticos (sem execução de código)")
@app_commands.describe(arquivo="Arquivo .lua obfuscado")
async def cmd_deob_static(interaction: discord.Interaction, arquivo: discord.Attachment):
    await _run_deob_interaction(
        interaction, arquivo,
        trace_level = "off",
        static_only = True,
        trace_only  = False,
        pretty      = True,
        title       = "Deobfuscador Estático",
    )

# ─── /deob-trace ──────────────────────────────────────────────────────────────

@tree.command(name="deob-trace", description="Só executa trace dinâmico (reproduz prints/API calls)")
@app_commands.describe(
    arquivo="Arquivo .lua obfuscado",
    modo="Modo de trace",
)
@app_commands.choices(modo=[
    app_commands.Choice(name="prints", value="prints"),
    app_commands.Choice(name="api",    value="api"),
])
async def cmd_deob_trace(
    interaction: discord.Interaction,
    arquivo: discord.Attachment,
    modo: app_commands.Choice[str] = None,
):
    await _run_deob_interaction(
        interaction, arquivo,
        trace_level = modo.value if modo else "prints",
        static_only = False,
        trace_only  = True,
        pretty      = True,
        title       = "Trace Dinâmico",
    )

# ─── /deob-help ───────────────────────────────────────────────────────────────

@tree.command(name="deob-help", description="Ajuda sobre os comandos do deobfuscator")
async def cmd_deob_help(interaction: discord.Interaction):
    embed = make_embed(
        title="📖 Prometheus Deobfuscator — Ajuda",
        color=discord.Color.green(),
        fields=[
            ("`/deob`",        "Pipeline completo: steps estáticos + trace dinâmico\n`trace`: prints | api | off", False),
            ("`/deob-static`", "Só steps estáticos — **não executa** o código\nMais seguro para scripts suspeitos", False),
            ("`/deob-trace`",  "Só trace dinâmico — reproduz prints/API calls na saída", False),
            ("Steps estáticos", (
                "• UnwrapFunction\n"
                "• ConstantArrayDecode\n"
                "• FoldNumbers / FoldConcats\n"
                "• EnvNormalize\n"
                "• UndoSplitStrings\n"
                "• UndoEncryptStrings\n"
                "• UndoProxifyLocals\n"
                "• Cleanup\n"
                "• UndoVmify"
            ), True),
            ("Limites", f"Tamanho máx: **{MAX_FILE_KB} KB**\nTimeout: **{TIMEOUT_SECS}s**", True),
        ]
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)

# ─── lógica comum ─────────────────────────────────────────────────────────────

async def _run_deob_interaction(
    interaction: discord.Interaction,
    arquivo: discord.Attachment,
    trace_level: str,
    static_only: bool,
    trace_only:  bool,
    pretty:      bool,
    title:       str,
):
    # Validações rápidas antes de deferir
    if not arquivo.filename.endswith(".lua"):
        await interaction.response.send_message(
            embed=make_embed("❌ Arquivo inválido", "Envie um arquivo `.lua`.", discord.Color.red()),
            ephemeral=True,
        )
        return

    if arquivo.size > MAX_FILE_KB * 1024:
        await interaction.response.send_message(
            embed=make_embed(
                "❌ Arquivo muito grande",
                f"Máximo: **{MAX_FILE_KB} KB** · Recebido: **{format_size(arquivo.size)}**",
                discord.Color.red(),
            ),
            ephemeral=True,
        )
        return

    # Adia a resposta (pode demorar)
    await interaction.response.defer(thinking=True)

    # Baixa o arquivo
    try:
        lua_bytes = await download_attachment(arquivo)
    except Exception as e:
        await interaction.followup.send(
            embed=make_embed("❌ Erro ao baixar arquivo", str(e), discord.Color.red())
        )
        return

    if lua_bytes is None:
        await interaction.followup.send(
            embed=make_embed("❌ Arquivo muito grande", f"Limite: {MAX_FILE_KB} KB", discord.Color.red())
        )
        return

    in_size = len(lua_bytes)

    # Roda o deobfuscator
    result_bytes, log, elapsed = await run_deob(
        lua_bytes,
        trace       = trace_level,
        static_only = static_only,
        trace_only  = trace_only,
        pretty      = pretty,
        timeout     = TIMEOUT_SECS,
    )

    # Monta resposta
    if result_bytes is None:
        embed = make_embed(
            f"❌ {title} — Falhou",
            f"```\n{truncate_log(log, 1800)}\n```",
            discord.Color.red(),
            fields=[("Tempo", f"{elapsed:.1f}s", True)],
        )
        await interaction.followup.send(embed=embed)
        return

    out_size    = len(result_bytes)
    ratio       = (1 - out_size / in_size) * 100 if in_size > 0 else 0
    out_name    = arquivo.filename.replace(".lua", ".deob.lua")
    log_preview = truncate_log(log, 1200)

    embed = make_embed(
        f"✅ {title}",
        f"```\n{log_preview}\n```",
        discord.Color.green(),
        fields=[
            ("Input",    format_size(in_size),  True),
            ("Output",   format_size(out_size),  True),
            ("Redução",  f"{ratio:.1f}%",         True),
            ("Tempo",    f"{elapsed:.1f}s",        True),
            ("Trace",    trace_level,              True),
            ("Pretty",   "✓" if pretty else "✗",  True),
        ],
    )

    out_file = discord.File(
        fp=__import__("io").BytesIO(result_bytes),
        filename=out_name,
    )

    await interaction.followup.send(embed=embed, file=out_file)


# ─── main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if not BOT_TOKEN:
        print("ERRO: variável de ambiente DISCORD_TOKEN não definida", file=sys.stderr)
        sys.exit(1)

    if not shutil.which(LUA_BINARY):
        print(f"AVISO: binário Lua '{LUA_BINARY}' não encontrado no PATH", file=sys.stderr)

    bot.run(BOT_TOKEN, log_level=20)  # logging.INFO
