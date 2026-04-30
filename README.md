# zsh-ai-autocomplete

Zsh plugin that suggests **shell commands using AI**, including from **natural language** input. Type `zshai search text in file` and get suggestions like `grep -r "text" .`. Powered by any **OpenAI-compatible** API, including **[Ollama](https://ollama.com)** for fully local/private usage.

## Requirements

- **Zsh 5.9+**
- `curl` and `jq` on `PATH`
- **OpenAI** or any **OpenAI-compatible** server (including **Ollama**)

## Install

Clone this repo and add to `~/.zshrc` (**at the end**, after other plugins):

```sh
source /path/to/zsh-ai-autocomplete/zsh-ai-autocomplete.plugin.zsh
```

Restart: `exec zsh`

## Onboarding

Run the interactive wizard:

```sh
zsh-ai-onboard
```

Choose **ollama** or **openai**. It writes `~/.config/zsh-ai-autocomplete/config.zsh`.

### Ollama quick start

With [Ollama](https://github.com/ollama/ollama) running and a model pulled:

```sh
ollama pull gemma3:1b          # recommended minimum
# ollama pull gemma4:e2b       # better quality, slower (~20s)

export ZSH_AI_PROVIDER=ollama
# Defaults: ZSH_AI_BASE_URL=http://127.0.0.1:11434/v1, ZSH_AI_MODEL=gemma3:1b
```

### Model recommendations

| Model | Size | Speed | Quality | Notes |
|-------|------|-------|---------|-------|
| `gemma3:270m` | 268M | ~1s | Poor | Too small to follow instructions |
| `gemma3:1b` | 1B | ~4s | OK | Default for Ollama, decent results |
| `gemma4:e2b` | 5.1B | ~20s | Excellent | Best quality, needs patience |
| `gpt-4o-mini` | cloud | ~1s | Excellent | Default for OpenAI |

## Usage

AI suggestions are triggered **on demand** — no API calls on every keystroke.

### Two ways to trigger

**1. Hotkey: `Ctrl-G`**

Type anything, then press `Ctrl-G` to get AI suggestions:

```
❯ find large files in current dir    # type this, press Ctrl-G
▶ find . -size +100M -type f
  du -ah . | sort -rh | head -20
  find . -maxdepth 1 -size +50M
  ls -lhS
  find . -type f -exec ls -lh {} + | sort -k5 -rh | head
[^Y accept | ^X ^N next | ^X ^P prev]
```

**2. Prefix: `zshai <query>` + Enter**

Type `zshai` followed by a natural language query, then press Enter:

```
❯ zshai search text in file          # press Enter
▶ grep -r "text" .
  grep -rn "text" *.txt
  find . -name "*.txt" -exec grep -l "text" {} \;
  ag "text"
  rg "text"
[^Y accept | ^X ^N next | ^X ^P prev]
```

The `zshai` prefix is stripped automatically — it won't try to run as a command.

### Keybindings

| Key | Action |
|-----|--------|
| `Ctrl-G` | Trigger AI suggestions for current input |
| `Ctrl-Y` | Accept the highlighted (`▶`) suggestion |
| `Ctrl-X Ctrl-N` | Cycle to next suggestion |
| `Ctrl-X Ctrl-P` | Cycle to previous suggestion |
| `Enter` | Normal execute (or trigger if prefixed with `zshai`) |

## Configuration

All settings via environment variables or `~/.config/zsh-ai-autocomplete/config.zsh`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `ZSH_AI_PROVIDER` | `openai` | `ollama` for local defaults |
| `ZSH_AI_BASE_URL` | depends on provider | API root (must include `/v1`) |
| `ZSH_AI_MODEL` | `gpt-4o-mini` / `gemma3:1b` | Model name |
| `ZSH_AI_API_KEY` | *(unset)* | Bearer token (optional for Ollama) |
| `ZSH_AI_PREFIX` | `zshai` | Prefix that triggers AI on Enter |
| `ZSH_AI_MAX_SUGGESTIONS` | `5` | Max suggestions to request |
| `ZSH_AI_TIMEOUT` | `20` | `curl --max-time` in seconds |
| `ZSH_AI_CURL_OPTS` | *(empty)* | Extra `curl` args |
| `ZSH_AI_DEBUG` | *(unset)* | Set to `1` for debug logging |
| `ZSH_AI_LOG` | `$TMPDIR/zsh-ai-autocomplete.log` | Log file path |

## Debugging

### Quick test (no ZLE needed)

```sh
zsh-ai-test search text in file
```

Prints config, HTTP request/response, and parsed suggestions.

### Debug mode

```sh
export ZSH_AI_DEBUG=1
exec zsh
```

Watch logs in another terminal:

```sh
tail -f $TMPDIR/zsh-ai-autocomplete.log
```

### Status check

```sh
zsh-ai-status
```

Shows config, keybindings, and Ollama connectivity.

## Compatibility

- **Powerlevel10k**: No console output during init. Source the plugin at the end of `~/.zshrc`.
- **fzf / zsh-autosuggestions**: No keybinding conflicts — uses `Ctrl-G`, `Ctrl-Y`, `Ctrl-X` combos.
- **Oh My Zsh**: Works as a custom plugin or direct source.

## Security

- **Nothing runs automatically.** Suggestions are displayed; you choose to accept and execute.
- Keep API keys in `config.zsh` with permissions **600**.

## Limitations

- Uses **USR1** signal for async refresh; conflicts with plugins that also trap `TRAPUSR1`.
- Small local models (< 1B params) give poor suggestions. Use at least `gemma3:1b`.
- First request to a model may be slow (cold start while Ollama loads weights).

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct, and the process for submitting pull requests to us.

## Code of Conduct

Our code of conduct is outlined in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Acknowledgments

* Hat tip to anyone whose code was used
* Inspiration
* etc
