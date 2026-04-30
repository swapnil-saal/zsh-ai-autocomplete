# zsh-ai-autocomplete — AI-backed command suggestions for Zsh (OpenAI-compatible API).
# Requires Zsh 5.9+ (line-pre-redraw), curl, and jq.

0=${(%):-%x}
ZSH_AI_AC_PLUGIN_DIR="${0:A:h}"

# ---------------------------------------------------------------------------
# Config (override in ~/.config/zsh-ai-autocomplete/config.zsh or env)
# ---------------------------------------------------------------------------
: "${ZSH_AI_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/zsh-ai-autocomplete}"
: "${ZSH_AI_CONFIG_FILE:=$ZSH_AI_CONFIG_DIR/config.zsh}"
: "${ZSH_AI_DEBOUNCE:=0.45}"
: "${ZSH_AI_MIN_CHARS:=2}"
: "${ZSH_AI_MAX_SUGGESTIONS:=5}"
: "${ZSH_AI_TIMEOUT:=12}"
: "${ZSH_AI_CURL_OPTS:=}"
: "${ZSH_AI_PROVIDER:=openai}"

[[ -r "$ZSH_AI_CONFIG_FILE" ]] && source "$ZSH_AI_CONFIG_FILE"

# Provider defaults (only if still unset after config / env)
case ${ZSH_AI_PROVIDER:-} in
  ollama)
    : "${ZSH_AI_BASE_URL:=http://127.0.0.1:11434/v1}"
    : "${ZSH_AI_MODEL:=gemma3:270m}"
    ;;
  *)
    : "${ZSH_AI_BASE_URL:=https://api.openai.com/v1}"
    : "${ZSH_AI_MODEL:=gpt-4o-mini}"
    ;;
esac

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
typeset -ga _zsh_ai_suggestions=()
typeset -g  _zsh_ai_tick=0
typeset -g  _zsh_ai_fetching=0
typeset -g  _zsh_ai_last_prompt_buf=''
typeset -g  _zsh_ai_suggestion_index=0
typeset -g  _zsh_ai_pending_after_fetch=0

# ---------------------------------------------------------------------------
# Version gate
# ---------------------------------------------------------------------------
autoload -Uz is-at-least add-zsh-hook
if ! is-at-least 5.9; then
  echo "[zsh-ai-autocomplete] Zsh 5.9+ required (need line-pre-redraw hook)." >&2
  return 1
fi

# ---------------------------------------------------------------------------
# Onboarding
# ---------------------------------------------------------------------------
_zsh_ai_onboard() {
  emulate -L zsh
  setopt errreturn nounset pipefail

  mkdir -p "$ZSH_AI_CONFIG_DIR"
  local key base model prov model_def
  echo "Zsh AI Autocomplete — setup"
  echo "Writes: $ZSH_AI_CONFIG_FILE"
  echo
  read 'prov?Provider — openai or ollama [openai]: '
  prov=${prov:-openai}
  prov=${prov:l}
  if [[ $prov == ollama ]]; then
    read 'key?API key (optional for local Ollama): '
    read 'base?Base URL [http://127.0.0.1:11434/v1]: '
    base=${base:-http://127.0.0.1:11434/v1}
    read 'model?Model [gemma3:270m]: '
    model=${model:-gemma3:270m}
  else
    prov=openai
    read 'key?API key: '
    read 'base?Base URL ['"$ZSH_AI_BASE_URL"']: '; base=${base:-$ZSH_AI_BASE_URL}
    read 'model?Model ['"$ZSH_AI_MODEL"']: '; model=${model:-$ZSH_AI_MODEL}
  fi

  umask 077
  {
    print -r -- '# zsh-ai-autocomplete — keep private.'
    print -r -- "export ZSH_AI_PROVIDER=${(q)prov}"
    print -r -- "export ZSH_AI_API_KEY=${(q)key}"
    print -r -- "export ZSH_AI_BASE_URL=${(q)base}"
    print -r -- "export ZSH_AI_MODEL=${(q)model}"
  } >"$ZSH_AI_CONFIG_FILE.tmp" && command mv -f "$ZSH_AI_CONFIG_FILE.tmp" "$ZSH_AI_CONFIG_FILE"
  echo
  echo "Done. Run: source $ZSH_AI_CONFIG_FILE ; exec zsh"
}

# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
_zsh_ai_require_config() {
  if [[ ${ZSH_AI_PROVIDER:-} == ollama ]]; then
    return 0
  fi
  if [[ -z "${ZSH_AI_API_KEY:-}" ]]; then
    [[ -n ${ZSH_AI_SILENT-} ]] && return 1
    echo "[zsh-ai-autocomplete] Set ZSH_AI_API_KEY or ZSH_AI_PROVIDER=ollama, or run: zsh-ai-onboard" >&2
    return 1
  fi
  return 0
}

_zsh_ai_fetch_sync() {
  emulate -L zsh
  setopt localoptions extendedglob
  local buf=$1
  _zsh_ai_require_config || return 1
  if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
    echo '[zsh-ai-autocomplete] Need curl and jq on PATH.' >&2
    return 1
  fi

  local sys='You suggest concise shell commands. Reply with exactly '
  sys+="$ZSH_AI_MAX_SUGGESTIONS lines. Each line is one command only: no numbering, markdown, or commentary. "
  sys+='Prefer POSIX/macOS/BSD commands when possible. If input is natural language, infer intent.'

  local url="$ZSH_AI_BASE_URL/chat/completions"
  local body
  body=$(jq -nc \
    --arg model "$ZSH_AI_MODEL" \
    --arg sys "$sys" \
    --arg user "$buf" \
    '{model:$model,messages:[{role:"system",content:$sys},{role:"user",content:$user}],temperature:0.2,stream:false}')

  local -a curl_args=(
    -sS --max-time "$ZSH_AI_TIMEOUT"
    -H 'Content-Type: application/json'
    -d "$body"
  )
  [[ -n "${ZSH_AI_API_KEY:-}" ]] && curl_args+=( -H "Authorization: Bearer $ZSH_AI_API_KEY" )
  [[ -n "${ZSH_AI_CURL_OPTS:-}" ]] && curl_args+=( $=ZSH_AI_CURL_OPTS )

  local json err
  err=$(mktemp)
  json=$(curl "${curl_args[@]}" "$url" 2>"$err") || { command cat "$err" >&2; command rm -f "$err"; return 1 }
  command rm -f "$err"

  local choices
  choices=$(print -r -- "$json" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || return 1
  if [[ -z "$choices" ]]; then
    print -r -- "$json" | jq -r '.error.message // .error // "empty response"' >&2 2>/dev/null || print -r -- "$json" >&2
    return 1
  fi

  local -a lines=()
  local line
  while IFS= read -r line; do
    line=${line//$'\r'/}
    line=${line## #}
    line=${line%% #}
    [[ -n $line ]] || continue
    line=${line/\`/}
    line=${line%`}
    [[ "$line" == \#* ]] && continue
    lines+=( "$line" )
  done <<<"$choices"

  _zsh_ai_suggestions=( "${(@)lines[1,$ZSH_AI_MAX_SUGGESTIONS]}" )
  (( $#_zsh_ai_suggestions )) || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Debounce + async (subshell + USR1)
# ---------------------------------------------------------------------------
_zsh_ai_schedule_fetch() {
  emulate -L zsh
  ((_zsh_ai_tick++))
  local tick=$_zsh_ai_tick
  sched +$ZSH_AI_DEBOUNCE "_zsh_ai_fire_fetch $tick"
}

_zsh_ai_fire_fetch() {
  emulate -L zsh
  local tick=$1
  (( tick == _zsh_ai_tick )) || return
  [[ -n ${ZLE_STATE-} ]] || return 0
  local buf=$BUFFER
  [[ ${#buf} -ge $ZSH_AI_MIN_CHARS ]] || { _zsh_ai_suggestions=(); POSTDISPLAY=''; return 0 }
  _zsh_ai_require_config 2>/dev/null || return 0
  if ((_zsh_ai_fetching)); then
    _zsh_ai_pending_after_fetch=1
    return 0
  fi
  _zsh_ai_fetching=1
  _zsh_ai_pending_after_fetch=0
  local out="${TMPDIR:-/tmp}/zsh-ai-ac.$USER.$$"
  (
    if _zsh_ai_fetch_sync "$buf"; then
      {
        print -rn "$buf" $'\0'
        local s
        for s in "${_zsh_ai_suggestions[@]}"; do
          print -rn "$s" $'\0'
        done
      } >"$out"
    else
      : >"$out"
    fi
    kill -USR1 $$
  ) &!
}

TRAPUSR1() {
  emulate -L zsh
  _zsh_ai_fetching=0

  local path="${TMPDIR:-/tmp}/zsh-ai-ac.$USER.$$"
  if [[ -f "$path" ]]; then
    local wanted buf_now line
    buf_now=$BUFFER
    _zsh_ai_suggestions=()

    {
      IFS= read -r -d '' wanted || wanted=''
      while IFS= read -r -d '' line; do
        [[ -n $line ]] && _zsh_ai_suggestions+=( "$line" )
      done
    } <"$path"
    command rm -f "$path"

    if [[ -n "$wanted" && "$wanted" == "$buf_now" ]]; then
      _zsh_ai_suggestion_index=0
      _zsh_ai_apply_postdisplay
      [[ -n ${ZLE_STATE-} ]] && zle .reset-prompt 2>/dev/null || true
    else
      _zsh_ai_suggestions=()
      _zsh_ai_apply_postdisplay
      [[ -n ${ZLE_STATE-} ]] && zle .reset-prompt 2>/dev/null || true
    fi
  fi

  if ((_zsh_ai_pending_after_fetch)); then
    _zsh_ai_pending_after_fetch=0
    _zsh_ai_schedule_fetch
  fi
}

# ---------------------------------------------------------------------------
# Display — inline ghost (dim suffix) + optional extra lines for other candidates
# ---------------------------------------------------------------------------
_zsh_ai_apply_postdisplay() {
  emulate -L zsh
  POSTDISPLAY=''
  (( ${#_zsh_ai_suggestions} )) || return 0

  local dim=$'\e[2m' rst=$'\e[0m'
  local i=$((_zsh_ai_suggestion_index + 1))
  local s=$_zsh_ai_suggestions[i] ghost=

  if [[ -n "$BUFFER" && "$s" == "${BUFFER}"* ]]; then
    ghost=${s:${#BUFFER}}
  else
    ghost="  ${s}"
  fi

  if [[ -n "$ghost" ]]; then
    POSTDISPLAY="${dim}${ghost}${rst}"
  fi

  if (( ${#_zsh_ai_suggestions} > 1 )); then
    [[ -n "$POSTDISPLAY" ]] && POSTDISPLAY+=$'\n'
    local j line
    for j in {1..${#_zsh_ai_suggestions}}; do
      (( j == i )) && continue
      line=$_zsh_ai_suggestions[j]
      POSTDISPLAY+="${dim}  ${line}${rst}"$'\n'
    done
    POSTDISPLAY=${POSTDISPLAY%$'\n'}
  fi
}

_zsh_ai_line_pre_redraw() {
  emulate -L zsh
  if [[ "$BUFFER" != "$_zsh_ai_last_prompt_buf" ]]; then
    _zsh_ai_last_prompt_buf=$BUFFER
    if [[ ${#BUFFER} -ge $ZSH_AI_MIN_CHARS ]]; then
      _zsh_ai_schedule_fetch
    else
      _zsh_ai_suggestions=()
      POSTDISPLAY=''
    fi
  fi
}

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------
_zsh_ai_accept_suggestion() {
  emulate -L zsh
  (( ${#_zsh_ai_suggestions} )) || return 0
  local i=$((_zsh_ai_suggestion_index + 1))
  BUFFER=$_zsh_ai_suggestions[i]
  CURSOR=${#BUFFER}
  _zsh_ai_suggestions=()
  _zsh_ai_suggestion_index=0
  POSTDISPLAY=''
}

_zsh_ai_cycle_next() {
  emulate -L zsh
  (( ${#_zsh_ai_suggestions} )) || return 0
  _zsh_ai_suggestion_index=$(( (_zsh_ai_suggestion_index + 1) % ${#_zsh_ai_suggestions} ))
  _zsh_ai_apply_postdisplay
  zle .reset-prompt
}

_zsh_ai_cycle_prev() {
  emulate -L zsh
  (( ${#_zsh_ai_suggestions} )) || return 0
  _zsh_ai_suggestion_index=$(( (_zsh_ai_suggestion_index - 1 + ${#_zsh_ai_suggestions}) % ${#_zsh_ai_suggestions} ))
  _zsh_ai_apply_postdisplay
  zle .reset-prompt
}

zle -N zsh-ai-accept-suggestion _zsh_ai_accept_suggestion
zle -N zsh-ai-cycle-next      _zsh_ai_cycle_next
zle -N zsh-ai-cycle-prev      _zsh_ai_cycle_prev

_zsh_ai_magic_tab() {
  emulate -L zsh
  if (( ${#_zsh_ai_suggestions} )); then
    zle zsh-ai-accept-suggestion
  else
    zle .expand-or-complete
  fi
}
zle -N zsh-ai-magic-tab _zsh_ai_magic_tab

# ---------------------------------------------------------------------------
# Hooks + keys
# ---------------------------------------------------------------------------
add-zsh-hook line-pre-redraw _zsh_ai_line_pre_redraw

bindkey '^I' zsh-ai-magic-tab
bindkey '^[[Z' zsh-ai-cycle-prev
bindkey '^X^n' zsh-ai-cycle-next

zsh-ai-onboard() { _zsh_ai_onboard "$@"; }
