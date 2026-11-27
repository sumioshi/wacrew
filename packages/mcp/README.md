
# wacrew-mcp

MCP server for [WACrew](https://wacrew.com.br): open-source WhatsApp AI automation.

It lets Claude Code, Codex, Cursor, Antigravity, Gemini CLI or any MCP client read, search and reply to your WhatsApp
groups and chats. Voice notes are transcribed, screenshots and videos can be inspected, PDFs read.
Replies go through a deterministic review that blocks robot-sounding text and are delivered at a
human pace (read receipt, typing indicator, pauses), cancelling themselves if the client writes again.

37 tools: `listar_grupos`, `ler_mensagens`, `buscar`, `resumo_do_dia`, `transcrever`, `ver_imagem`,
`assistir_video`, `ler_documento`, `preparar_resposta`, `revisar_texto`, `responder`,
`status_envio`, `cancelar_envio` and more. Full list in the
[main README](https://github.com/sumioshi/wacrew#mcp-tools).

## Requirements

A running WACrew panel (the collector that connects to WhatsApp). Run it with Docker on a VPS:

```bash
git clone https://github.com/sumioshi/wacrew && cd wacrew
PANEL_USER=admin PANEL_PASS=change-me docker compose up -d
```

Open `http://<server-ip>:3000/config` and scan the QR code with WhatsApp.

## Setup

Point the MCP at your panel with the same login:

```bash
claude mcp add wacrew \
  -e WAC_CLOUD_URL=https://your-panel.example.com \
  -e WAC_CLOUD_USER=admin \
  -e WAC_CLOUD_PASS=change-me \
  -- npx -y wacrew-mcp
```

In Antigravity (`agy` CLI), flags go before the name:

```bash
agy mcp add \
  -e WAC_CLOUD_URL=https://your-panel.example.com \
  -e WAC_CLOUD_USER=admin \
  -e WAC_CLOUD_PASS=change-me \
  wacrew npx -y wacrew-mcp
```

In Codex, add the following to `~/.codex/config.toml`:

```toml
[mcp_servers.wacrew]
command = "npx"
args = ["-y", "wacrew-mcp"]

[mcp_servers.wacrew.env]
WAC_CLOUD_URL = "https://your-panel.example.com"
WAC_CLOUD_USER = "admin"
WAC_CLOUD_PASS = "change-me"
```

**More than one WhatsApp.** One server can talk to several panels. Add the others in `WAC_CONTAS` as `name=https://login:password@address`, separated by spaces (or put them after the main address in `WAC_CLOUD_URL`). Every tool then takes an optional `conta` parameter, and the agent picks the account per call. `WAC_CONTA_NOME` names the default one:

```bash
claude mcp add wacrew -e WAC_CLOUD_URL=https://work.example.com \
  -e WAC_CLOUD_USER=admin -e WAC_CLOUD_PASS=change-me -e WAC_CONTA_NOME=work \
  -e WAC_CONTAS="personal=https://admin:other-pass@personal.example.com" -- npx -y wacrew-mcp
```

Or in any MCP client config:

```json
{
  "mcpServers": {
    "wacrew": {
      "command": "npx",
      "args": ["-y", "wacrew-mcp"],
      "env": {
        "WAC_CLOUD_URL": "https://your-panel.example.com",
        "WAC_CLOUD_USER": "admin",
        "WAC_CLOUD_PASS": "change-me"
      }
    }
  }
}
```

| Variable | |
|---|---|
| `WAC_CLOUD_URL` | Your WACrew panel URL. Put HTTPS in front of it (Caddy, a tunnel, etc.). |
| `WAC_CLOUD_USER`, `WAC_CLOUD_PASS` | The panel login (`PANEL_USER` / `PANEL_PASS`). |
| `WAC_DATA_DIR` | Optional. Local cache for downloaded media. Default `~/.wacrew/data`. |

Running the collector on the same machine instead? Set `WAC_DATA_DIR` to its `data/` folder and
leave `WAC_CLOUD_URL` empty: the MCP reads the files directly.

## Safety

Sending is the user's call. Each chat has a mode: `confirmar` (default, the agent shows the text
and waits for your OK) or `autonomo`. WACrew uses Baileys (WhatsApp Web multi-device), not the
official API: use it with people who already talk to you, never for bulk messaging.

## License

Apache 2.0 © [Rodrigo Sumioshi](https://rodrigosumioshi.com). Source: [sumioshi/wacrew](https://github.com/sumioshi/wacrew).
