# zsh-ai-autocomplete

Zsh plugin that suggests **shell commands from what you type**, including **natural language** (for example: you type `list directory` and see ghost hints like `ls -l`). Suggestions are fetched from an **OpenAI-compatible** HTTP API (`/v1/chat/completions`).

Inspired by [marlonrichert/zsh-autocomplete](https://github.com/marlonrichert/zsh-autocomplete): suggestions update as you type (debounced) and you can accept or cycle them from the keyboard.

## Requirements

- **Zsh 5.9+** (uses the `line-pre-redraw` hook)
- `curl` and `jq` on `PATH`
- **OpenAI** or any **OpenAI-compatible** server (including **[Ollama](https://ollama.com)** on port 11434)

## Install

Clone or copy this repo, then in `~/.zshrc` (before any heavy completion customization, if possible):

```sh
source /path/to/zsh-ai-autocomplete/zsh-ai-autocomplete.plugin.zsh
```

Restart the shell: `exec zsh`

## Onboarding (config file)

Run the interactive wizard:

```sh
zsh-ai-onboard
```

Choose **ollama** or **openai**. It writes `~/.config/zsh-ai-autocomplete/config.zsh`. Then:

```sh
source ~/.config/zsh-ai-autocomplete/config.zsh
exec zsh
```

### Ollama quick start (e.g. `gemma3:270m`)

With [Ollama](https://github.com/ollama/ollama) running and the model pulled (`ollama pull gemma3:270m`), a minimal config is:

```sh
export ZSH_AI_PROVIDER=ollama
# Optional: ZSH_AI_API_KEY — not needed for default local Ollama
# Defaults: ZSH_AI_BASE_URL=http://127.0.0.1:11434/v1 , ZSH_AI_MODEL=gemma3:270m
```

Then `source` the plugin. Requests use `stream:false` in the JSON body so the client can parse one JSON object (no SSE).

## Usage

1. Type at least **`ZSH_AI_MIN_CHARS`** characters (default **2**).
2. After a short pause (**`ZSH_AI_DEBOUNCE`**, default **0.45s**), the plugin requests suggestions.
3. **Inline ghost text** (dim) appears **after** your input on the same row:
   - If your buffer is a **prefix** of the active suggestion, the ghost is only the **rest** of that command (like `zsh-autosuggestions`).
   - If not (e.g. natural language), the ghost shows the **full** suggested command after two spaces.
4. **Extra candidates** (if any) appear as dim lines **below** that ghost line.
5. **Tab** — replace the line with the **active** suggestion (full command).
6. **Ctrl+X Ctrl+N** — next suggestion (updates ghost + list).
7. **Shift+Tab** — previous suggestion.
8. If there are no AI suggestions yet, **Tab** runs normal **expand-or-complete**.

## Configuration (environment)

| Variable | Default | Meaning |
|----------|---------|---------|
| `ZSH_AI_CONFIG_FILE` | `~/.config/zsh-ai-autocomplete/config.zsh` | Sourced if readable |
| `ZSH_AI_PROVIDER` | `openai` | Set to `ollama` for local defaults (no API key required) |
| `ZSH_AI_BASE_URL` | depends on provider | API root (must include `/v1` for compatibility mode) |
| `ZSH_AI_MODEL` | `gpt-4o-mini` or `gemma3:270m` (ollama) | Model name |
| `ZSH_AI_API_KEY` | *(unset)* | Sent as `Authorization: Bearer` only if non-empty |
| `ZSH_AI_DEBOUNCE` | `0.45` | Seconds after typing before request |
| `ZSH_AI_MIN_CHARS` | `2` | Minimum buffer length to query |
| `ZSH_AI_MAX_SUGGESTIONS` | `5` | Max lines to ask the model for |
| `ZSH_AI_TIMEOUT` | `12` | `curl --max-time` |
| `ZSH_AI_CURL_OPTS` | *(empty)* | Extra args to `curl` (split on spaces) |
| `ZSH_AI_SILENT` | unset | If set, suppress missing-key messages |

## Security

- The model may suggest dangerous commands. **Nothing runs automatically**; you always press **Enter** yourself.
- Keep secrets in `config.zsh` with permissions **600**.

## Limitations

- Uses **USR1** for async refresh; another plugin that sets `TRAPUSR1` may conflict.
- With AI suggestions visible, **Tab** accepts a suggestion instead of completing; change the line or disable the plugin if you need Tab completion only.

## License

MIT
