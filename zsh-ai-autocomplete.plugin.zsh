# zsh-ai-autocomplete — AI-backed command suggestions for Zsh (OpenAI-compatible API).
# Requires Zsh 5.9+, curl, and jq.
#
# Usage:
#   Ctrl-G          — trigger AI suggestions for current input
#   zshai <query>   — type a natural language query and press Enter
#   Ctrl-Y          — accept the highlighted suggestion
#   Ctrl-X Ctrl-N   — cycle to next suggestion
#   Ctrl-X Ctrl-P   — cycle to previous suggestion

0=${(%):-%x}
ZSH_AI_AC_PLUGIN_DIR="${0:A:h}"

# ---------------------------------------------------------------------------
# Config (override in ~/.config/zsh-ai-autocomplete/config.zsh or env)
# ---------------------------------------------------------------------------
: "${ZSH_AI_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/zsh-ai-autocomplete}"
: "${ZSH_AI_CONFIG_FILE:=$ZSH_AI_CONFIG_DIR/config.zsh}"
: "${ZSH_AI_MAX_SUGGESTIONS:=5}"
: "${ZSH_AI_TIMEOUT:=20}"
: "${ZSH_AI_CURL_OPTS:=}"
: "${ZSH_AI_PROVIDER:=openai}"
: "${ZSH_AI_PREFIX:=zshai}"
: "${ZSH_AI_DEBUG:=}"
: "${ZSH_AI_LOG:=${TMPDIR:-/tmp}/zsh-ai-autocomplete.log}"

[[ -r "$ZSH_AI_CONFIG_FILE" ]] && source "$ZSH_AI_CONFIG_FILE"

# Provider defaults (only if still unset after config / env)
case ${ZSH_AI_PROVIDER:-} in
  ollama)
    : "${ZSH_AI_BASE_URL:=http://127.0.0.1:11434/v1}"
    : "${ZSH_AI_MODEL:=gemma3:1b}"
    ;;
  *)
    : "${ZSH_AI_BASE_URL:=https://api.openai.com/v1}"
    : "${ZSH_AI_MODEL:=gpt-4o-mini}"
    ;;
esac

# ---------------------------------------------------------------------------
# Debug helper
# ---------------------------------------------------------------------------
_zsh_ai_dbg() {
  [[ -n "${ZSH_AI_DEBUG:-}" ]] || return 0
  local ts
  ts=$(date '+%H:%M:%S' 2>/dev/null) || ts='-'
  print -r -- "[$ts] $*" >>"$ZSH_AI_LOG"
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
typeset -ga _zsh_ai_suggestions=()
typeset -g  _zsh_ai_suggestion_index=0
typeset -g  _zsh_ai_bg_pid=0
typeset -g  _zsh_ai_async_fd=0
typeset -g  _zsh_ai_query_buf=''

# ---------------------------------------------------------------------------
# Onboarding
# ---------------------------------------------------------------------------
_zsh_ai_onboard() {
  emulate -L zsh
  setopt errreturn nounset pipefail

  mkdir -p "$ZSH_AI_CONFIG_DIR"
  local key base model prov
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
    read 'model?Model [gemma3:1b]: '
    model=${model:-gemma3:1b}
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
    _zsh_ai_dbg "FAIL require_config: ZSH_AI_API_KEY not set"
    return 1
  fi
  return 0
}

_zsh_ai_fetch_sync() {
  emulate -L zsh
  setopt localoptions extendedglob
  local buf=$1
  _zsh_ai_dbg "fetch_sync: buf='$buf'"
  _zsh_ai_require_config || return 1
  if ! command -v curl >/dev/null; then return 1; fi
  if ! command -v jq  >/dev/null; then return 1; fi

  local n=$ZSH_AI_MAX_SUGGESTIONS

  local url="$ZSH_AI_BASE_URL/chat/completions"
  local body
  body=$(jq -nc \
    --argjson n "$n" \
    --arg model "$ZSH_AI_MODEL" \
    --arg user "$buf" \
    '{model:$model,temperature:0.5,stream:false,messages:[
      {role:"system",content:("Suggest exactly "+($n|tostring)+" shell commands. One per line. No markdown. No backticks. No numbering. No explanation.")},
      {role:"user",content:"list files"},
      {role:"assistant",content:"ls -la\nls -lh\nls -lt\nfind . -maxdepth 1 -type f\nls -1"},
      {role:"user",content:"search text in file"},
      {role:"assistant",content:"grep -r \"text\" .\ngrep -rn \"text\" *.txt\nfind . -name \"*.txt\" -exec grep -l \"text\" {} \\;\nag \"text\"\nrg \"text\""},
      {role:"user",content:"disk usage"},
      {role:"assistant",content:"df -h\ndu -sh *\ndu -sh .\ndu -ah . | sort -rh | head -20\nncdu"},
      {role:"user",content:$user}
    ]}')

  _zsh_ai_dbg "fetch_sync: url=$url model=$ZSH_AI_MODEL"

  local -a curl_args=(
    -sS --max-time "$ZSH_AI_TIMEOUT"
    -H 'Content-Type: application/json'
    -d "$body"
  )
  [[ -n "${ZSH_AI_API_KEY:-}" ]] && curl_args+=( -H "Authorization: Bearer $ZSH_AI_API_KEY" )
  [[ -n "${ZSH_AI_CURL_OPTS:-}" ]] && curl_args+=( $=ZSH_AI_CURL_OPTS )

  local json err rc=0
  err=$(mktemp)
  json=$(curl "${curl_args[@]}" "$url" 2>"$err") || rc=$?
  local curl_err=$(<$err)
  { rm -f "$err" } 2>/dev/null
  if (( rc )); then
    _zsh_ai_dbg "FAIL fetch_sync: curl exit=$rc stderr='$curl_err'"
    return 1
  fi
  _zsh_ai_dbg "fetch_sync: raw json=${json:0:300}"

  local choices
  choices=$(print -r -- "$json" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || {
    _zsh_ai_dbg "FAIL fetch_sync: jq parse failed"
    return 1
  }
  if [[ -z "$choices" ]]; then
    _zsh_ai_dbg "FAIL fetch_sync: empty response"
    return 1
  fi
  _zsh_ai_dbg "fetch_sync: choices='${choices:0:200}'"

  local -a lines=()
  local line
  while IFS= read -r line; do
    line=${line//$'\r'/}
    line=${line## #}
    line=${line%% #}
    [[ -n $line ]] || continue
    line=${line//\`/}
    [[ "$line" == \#* ]] && continue
    case "$line" in
      bash|sh|zsh|fish|shell|powershell|cmd|'') continue ;;
    esac
    if [[ "$line" =~ '^[0-9]+[.\)]\s*(.*)$' ]]; then
      line=${match[1]}
      [[ -n $line ]] || continue
    fi
    lines+=( "$line" )
  done <<<"$choices"

  _zsh_ai_suggestions=( "${(@)lines[1,$ZSH_AI_MAX_SUGGESTIONS]}" )
  _zsh_ai_dbg "fetch_sync: parsed ${#_zsh_ai_suggestions} suggestions"
  (( $#_zsh_ai_suggestions )) || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Async fetch (background subshell + USR1 signal + zle -F pipe)
# ---------------------------------------------------------------------------
_zsh_ai_trigger_fetch() {
  emulate -L zsh
  if (( _zsh_ai_bg_pid > 0 )); then
    kill $_zsh_ai_bg_pid 2>/dev/null
    _zsh_ai_bg_pid=0
  fi

  _zsh_ai_require_config 2>/dev/null || return 0

  local buf=$1
  _zsh_ai_query_buf=$buf
  local out="${TMPDIR:-/tmp}/zsh-ai-ac.$USER.$$"
  _zsh_ai_dbg "trigger: buf='$buf'"

  (
    if _zsh_ai_fetch_sync "$buf"; then
      {
        printf '%s\0' "$buf"
        local s
        for s in "${_zsh_ai_suggestions[@]}"; do
          printf '%s\0' "$s"
        done
      } >"$out"
      _zsh_ai_dbg "subshell: wrote ${#_zsh_ai_suggestions} suggestions"
    else
      : >"$out"
      _zsh_ai_dbg "subshell: fetch failed"
    fi
    kill -USR1 $$ 2>/dev/null
  ) &!
  _zsh_ai_bg_pid=$!
  _zsh_ai_dbg "trigger: launched pid=$_zsh_ai_bg_pid"
}

# ---------------------------------------------------------------------------
# Display — show suggestions via zle -M
# ---------------------------------------------------------------------------
_zsh_ai_refresh_widget() {
  if (( ${#_zsh_ai_suggestions} )); then
    local i=$(( _zsh_ai_suggestion_index + 1 ))
    local msg='' j
    for j in {1..${#_zsh_ai_suggestions}}; do
      if (( j == i )); then
        msg+="▶ ${_zsh_ai_suggestions[j]}"$'\n'
      else
        msg+="  ${_zsh_ai_suggestions[j]}"$'\n'
      fi
    done
    msg+="[^Y accept | ^X ^N next | ^X ^P prev]"
    zle -M "$msg"
  else
    zle -M ''
  fi
}

# ---------------------------------------------------------------------------
# Async notification pipe (zle -F)
# ---------------------------------------------------------------------------
_zsh_ai_async_handler() {
  local fd=$1 buf=''
  zmodload -e zsh/system && sysread -i $fd buf 2>/dev/null || {
    local dummy
    IFS= read -r -u $fd dummy 2>/dev/null || true
  }
  _zsh_ai_dbg "async_handler: ${#_zsh_ai_suggestions} sugg"
  zle zsh-ai-refresh 2>/dev/null
}

_zsh_ai_setup_async_fd() {
  if (( _zsh_ai_async_fd > 0 )); then
    zle -F $_zsh_ai_async_fd 2>/dev/null
    exec {_zsh_ai_async_fd}>&- 2>/dev/null
    _zsh_ai_async_fd=0
  fi
  zmodload zsh/system 2>/dev/null || true
  local tmpfifo="${TMPDIR:-/tmp}/zsh-ai-fifo.$USER.$$"
  command rm -f "$tmpfifo"
  command mkfifo "$tmpfifo" 2>/dev/null || return 1
  exec {_zsh_ai_async_fd}<>"$tmpfifo"
  command rm -f "$tmpfifo"
  zle -F $_zsh_ai_async_fd _zsh_ai_async_handler
  _zsh_ai_dbg "setup_async: fd=$_zsh_ai_async_fd"
}

TRAPUSR1() {
  local path="${TMPDIR:-/tmp}/zsh-ai-ac.$USER.$$"
  [[ -f "$path" ]] || return 0

  local wanted line
  local -a new_suggestions=()
  {
    IFS= read -r -d '' wanted || wanted=''
    while IFS= read -r -d '' line; do
      [[ -n $line ]] && new_suggestions+=( "$line" )
    done
  } <"$path"
  { rm -f "$path" } 2>/dev/null

  _zsh_ai_dbg "TRAPUSR1: wanted='${wanted:0:60}' query='${_zsh_ai_query_buf:0:60}' got=${#new_suggestions}"

  if [[ -n "$wanted" && "$wanted" == "$_zsh_ai_query_buf" ]]; then
    _zsh_ai_suggestions=( "${new_suggestions[@]}" )
    _zsh_ai_suggestion_index=0
  else
    _zsh_ai_dbg "TRAPUSR1: mismatch, discarding"
    _zsh_ai_suggestions=()
  fi

  if (( _zsh_ai_async_fd > 0 )); then
    if zmodload -e zsh/system 2>/dev/null; then
      syswrite -o $_zsh_ai_async_fd "x" 2>/dev/null
    else
      print -u $_zsh_ai_async_fd "x" 2>/dev/null
    fi
    _zsh_ai_dbg "TRAPUSR1: notified async fd"
  fi
}

# ---------------------------------------------------------------------------
# Widgets
# ---------------------------------------------------------------------------

# Ctrl-G: trigger AI suggestions for current buffer
_zsh_ai_trigger_widget() {
  emulate -L zsh
  local query=$BUFFER
  if [[ ${#query} -lt 2 ]]; then
    zle -M "Type something first, then press ^G"
    return
  fi
  zle -M "⏳ Fetching AI suggestions..."
  _zsh_ai_trigger_fetch "$query"
}

# Accept the highlighted suggestion
_zsh_ai_accept_suggestion() {
  emulate -L zsh
  (( ${#_zsh_ai_suggestions} )) || return 0
  local i=$((_zsh_ai_suggestion_index + 1))
  BUFFER=$_zsh_ai_suggestions[i]
  CURSOR=${#BUFFER}
  _zsh_ai_suggestions=()
  _zsh_ai_suggestion_index=0
  zle -M ''
}

_zsh_ai_cycle_next() {
  emulate -L zsh
  (( ${#_zsh_ai_suggestions} )) || return 0
  _zsh_ai_suggestion_index=$(( (_zsh_ai_suggestion_index + 1) % ${#_zsh_ai_suggestions} ))
  zle zsh-ai-refresh
}

_zsh_ai_cycle_prev() {
  emulate -L zsh
  (( ${#_zsh_ai_suggestions} )) || return 0
  _zsh_ai_suggestion_index=$(( (_zsh_ai_suggestion_index - 1 + ${#_zsh_ai_suggestions}) % ${#_zsh_ai_suggestions} ))
  zle zsh-ai-refresh
}

# Enter key: intercept "zshai ..." prefix, otherwise normal accept-line
_zsh_ai_accept_line() {
  emulate -L zsh
  local prefix="${ZSH_AI_PREFIX:-zshai}"
  if [[ "$BUFFER" == ${prefix}\ * ]]; then
    local query=${BUFFER#${prefix} }
    if [[ -n "$query" ]]; then
      BUFFER=$query
      CURSOR=${#BUFFER}
      zle -M "⏳ Fetching AI suggestions for: $query"
      _zsh_ai_trigger_fetch "$query"
      return
    fi
  fi
  _zsh_ai_suggestions=()
  zle -M ''
  zle .accept-line
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
_zsh_ai_setup_zle() {
  emulate -L zsh

  zle -N zsh-ai-trigger _zsh_ai_trigger_widget
  zle -N zsh-ai-accept-suggestion _zsh_ai_accept_suggestion
  zle -N zsh-ai-cycle-next _zsh_ai_cycle_next
  zle -N zsh-ai-cycle-prev _zsh_ai_cycle_prev
  zle -N zsh-ai-refresh _zsh_ai_refresh_widget
  zle -N zsh-ai-accept-line _zsh_ai_accept_line

  _zsh_ai_setup_async_fd

  bindkey '^g'    zsh-ai-trigger            # Ctrl-G: trigger AI
  bindkey '^y'    zsh-ai-accept-suggestion  # Ctrl-Y: accept
  bindkey '^x^n'  zsh-ai-cycle-next         # Ctrl-X Ctrl-N: next
  bindkey '^x^p'  zsh-ai-cycle-prev         # Ctrl-X Ctrl-P: prev
  bindkey '^M'    zsh-ai-accept-line        # Enter: intercept prefix

  _zsh_ai_dbg "setup: widgets + keybindings ready"
}

if [[ -o interactive ]]; then
  _zsh_ai_setup_zle
fi

# ---------------------------------------------------------------------------
# CLI commands
# ---------------------------------------------------------------------------
zsh-ai-onboard() { _zsh_ai_onboard "$@"; }

zsh-ai-rebind() {
  bindkey '^g'    zsh-ai-trigger
  bindkey '^y'    zsh-ai-accept-suggestion
  bindkey '^x^n'  zsh-ai-cycle-next
  bindkey '^x^p'  zsh-ai-cycle-prev
  bindkey '^M'    zsh-ai-accept-line
  echo "Rebound: ^G=trigger, ^Y=accept, ^X^N=next, ^X^P=prev, Enter=prefix"
}

zsh-ai-status() {
  emulate -L zsh
  echo "--- zsh-ai-status ---"
  echo "Provider : ${ZSH_AI_PROVIDER:-openai}"
  echo "Base URL : $ZSH_AI_BASE_URL"
  echo "Model    : $ZSH_AI_MODEL"
  echo "API Key  : ${ZSH_AI_API_KEY:+set (${#ZSH_AI_API_KEY} chars)}${ZSH_AI_API_KEY:-NOT SET}"
  echo "Prefix   : ${ZSH_AI_PREFIX:-zshai}"
  echo "Debug    : ${ZSH_AI_DEBUG:-off}"
  echo "Log file : $ZSH_AI_LOG"
  echo
  echo "Trigger modes:"
  echo "  ^G             — trigger AI for current input"
  echo "  ${ZSH_AI_PREFIX:-zshai} <query>  — type and press Enter"
  echo
  echo "Keybindings:"
  echo "  ^G         : $(bindkey '^g' 2>/dev/null | command awk '{print $2}')"
  echo "  ^Y         : $(bindkey '^y' 2>/dev/null | command awk '{print $2}')"
  echo "  ^X ^N      : $(bindkey '^x^n' 2>/dev/null | command awk '{print $2}')"
  echo "  ^X ^P      : $(bindkey '^x^p' 2>/dev/null | command awk '{print $2}')"
  echo
  echo "Ollama reachable:"
  if [[ ${ZSH_AI_PROVIDER:-} == ollama ]]; then
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${ZSH_AI_BASE_URL%/v1}" 2>/dev/null) || code=FAIL
    echo "  GET ${ZSH_AI_BASE_URL%/v1} → HTTP $code"
  else
    echo "  (not using ollama)"
  fi
  echo "--- done ---"
}

zsh-ai-test() {
  emulate -L zsh
  local query=${*:-list files}
  echo "--- zsh-ai-test ---"
  echo "Provider : ${ZSH_AI_PROVIDER:-openai}"
  echo "Base URL : $ZSH_AI_BASE_URL"
  echo "Model    : $ZSH_AI_MODEL"
  echo "API Key  : ${ZSH_AI_API_KEY:+set (${#ZSH_AI_API_KEY} chars)}${ZSH_AI_API_KEY:-NOT SET}"
  echo "Query    : $query"
  echo

  if ! command -v curl >/dev/null; then echo "ERROR: curl not found"; return 1; fi
  if ! command -v jq  >/dev/null; then echo "ERROR: jq not found";  return 1; fi

  local n=$ZSH_AI_MAX_SUGGESTIONS
  local url="$ZSH_AI_BASE_URL/chat/completions"
  local body
  body=$(jq -nc \
    --argjson n "$n" \
    --arg model "$ZSH_AI_MODEL" \
    --arg user "$query" \
    '{model:$model,temperature:0.5,stream:false,messages:[
      {role:"system",content:("Suggest exactly "+($n|tostring)+" shell commands. One per line. No markdown. No backticks. No numbering. No explanation.")},
      {role:"user",content:"list files"},
      {role:"assistant",content:"ls -la\nls -lh\nls -lt\nfind . -maxdepth 1 -type f\nls -1"},
      {role:"user",content:"search text in file"},
      {role:"assistant",content:"grep -r \"text\" .\ngrep -rn \"text\" *.txt\nfind . -name \"*.txt\" -exec grep -l \"text\" {} \\;\nag \"text\"\nrg \"text\""},
      {role:"user",content:"disk usage"},
      {role:"assistant",content:"df -h\ndu -sh *\ndu -sh .\ndu -ah . | sort -rh | head -20\nncdu"},
      {role:"user",content:$user}
    ]}')

  echo ">> POST $url"
  echo ">> Body (first 200): ${body:0:200}"
  echo

  local -a curl_args=(
    -sS -w '\n%{http_code}' --max-time "$ZSH_AI_TIMEOUT"
    -H 'Content-Type: application/json'
    -d "$body"
  )
  [[ -n "${ZSH_AI_API_KEY:-}" ]] && curl_args+=( -H "Authorization: Bearer $ZSH_AI_API_KEY" )
  [[ -n "${ZSH_AI_CURL_OPTS:-}" ]] && curl_args+=( $=ZSH_AI_CURL_OPTS )

  local raw rc=0
  raw=$(curl "${curl_args[@]}" "$url" 2>&1) || rc=$?
  if (( rc )); then
    echo "ERROR: curl exit code $rc"
    echo "$raw"
    return 1
  fi

  local http_code=${raw##*$'\n'}
  local json=${raw%$'\n'*}

  echo "<< HTTP $http_code"
  echo "<< Response (first 500):"
  echo "${json:0:500}"
  echo

  if (( http_code < 200 || http_code >= 300 )); then
    echo "ERROR: non-2xx response"
    return 1
  fi

  local choices
  choices=$(print -r -- "$json" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  if [[ -z "$choices" ]]; then
    echo "ERROR: no .choices[0].message.content in response"
    return 1
  fi

  echo "Suggestions:"
  local cnt=0 line
  while IFS= read -r line; do
    line=${line//$'\r'/}; line=${line## #}; line=${line%% #}
    [[ -n $line ]] || continue
    line=${line//\`/}
    [[ "$line" == \#* ]] && continue
    case "$line" in bash|sh|zsh|fish|shell|'') continue ;; esac
    (( ++cnt ))
    echo "  $cnt) $line"
  done <<<"$choices"
  (( cnt )) || echo "  (none parsed)"
  echo "--- done ---"
}
