# zsh-ai-autocomplete — AI-backed command suggestions for Zsh (OpenAI-compatible API).
# Requires Zsh 5.9+, curl, and jq.

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
: "${ZSH_AI_TIMEOUT:=20}"
: "${ZSH_AI_CURL_OPTS:=}"
: "${ZSH_AI_PROVIDER:=openai}"
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
# Debug helper — writes to $ZSH_AI_LOG when ZSH_AI_DEBUG is set
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
typeset -g  _zsh_ai_last_prompt_buf=''
typeset -g  _zsh_ai_suggestion_index=0
typeset -g  _zsh_ai_bg_pid=0
typeset -g  _zsh_ai_async_fd=0

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
    _zsh_ai_dbg "FAIL require_config: ZSH_AI_API_KEY not set, provider=${ZSH_AI_PROVIDER:-unset}"
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
  if ! command -v curl >/dev/null; then
    _zsh_ai_dbg "FAIL fetch_sync: curl not found"
    return 1
  fi
  if ! command -v jq >/dev/null; then
    _zsh_ai_dbg "FAIL fetch_sync: jq not found"
    return 1
  fi

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
    _zsh_ai_dbg "FAIL fetch_sync: jq parse failed on json"
    return 1
  }
  if [[ -z "$choices" ]]; then
    local api_err
    api_err=$(print -r -- "$json" | jq -r '.error.message // .error // "empty response"' 2>/dev/null) || api_err="(unparseable)"
    _zsh_ai_dbg "FAIL fetch_sync: no choices; error='$api_err'"
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
    # skip bare language tags from code-fenced responses
    case "$line" in
      bash|sh|zsh|fish|shell|powershell|cmd|'') continue ;;
    esac
    # strip leading "1. " / "2) " numbering
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
# Debounce + async fetch (kill-previous-subshell pattern + USR1)
# ---------------------------------------------------------------------------
_zsh_ai_schedule_fetch() {
  emulate -L zsh
  # Kill the previous sleep/fetch subshell if still running
  if (( _zsh_ai_bg_pid > 0 )); then
    kill $_zsh_ai_bg_pid 2>/dev/null
    _zsh_ai_bg_pid=0
  fi

  _zsh_ai_require_config 2>/dev/null || return 0

  local buf=$BUFFER
  local out="${TMPDIR:-/tmp}/zsh-ai-ac.$USER.$$"
  _zsh_ai_dbg "schedule: buf='$buf'"

  (
    # Debounce: sleep first, then fetch
    sleep "$ZSH_AI_DEBOUNCE" 2>/dev/null || exit 0
    _zsh_ai_dbg "subshell: debounce done, fetching for '$buf'"

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
  _zsh_ai_dbg "schedule: launched pid=$_zsh_ai_bg_pid"
}

_zsh_ai_refresh_widget() {
  _zsh_ai_dbg "refresh_widget: ${#_zsh_ai_suggestions} sugg, BUFFER='${BUFFER:0:40}'"
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
# Async notification via pipe + zle -F
# Signal handlers (TRAPUSR1) cannot call ZLE widgets. Instead, we write a
# byte to a self-pipe; zle -F fires the handler inside ZLE context where
# POSTDISPLAY and zle .reset-prompt work.
# ---------------------------------------------------------------------------
_zsh_ai_async_handler() {
  local fd=$1 buf=''
  zmodload -e zsh/system && sysread -i $fd buf 2>/dev/null || {
    local dummy
    IFS= read -r -u $fd dummy 2>/dev/null || true
  }
  _zsh_ai_dbg "async_handler: ${#_zsh_ai_suggestions} sugg, calling widget"
  zle zsh-ai-refresh 2>/dev/null
  _zsh_ai_dbg "async_handler: widget done"
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
  command mkfifo "$tmpfifo" 2>/dev/null || {
    _zsh_ai_dbg "FAIL setup_async: mkfifo failed"
    return 1
  }
  exec {_zsh_ai_async_fd}<>"$tmpfifo"
  command rm -f "$tmpfifo"
  zle -F $_zsh_ai_async_fd _zsh_ai_async_handler
  _zsh_ai_dbg "setup_async: fd=$_zsh_ai_async_fd"
}

TRAPUSR1() {
  local path="${TMPDIR:-/tmp}/zsh-ai-ac.$USER.$$"
  if [[ ! -f "$path" ]]; then
    _zsh_ai_dbg "TRAPUSR1: no result file ($path)"
    return 0
  fi

  local wanted line
  local -a new_suggestions=()

  {
    IFS= read -r -d '' wanted || wanted=''
    while IFS= read -r -d '' line; do
      [[ -n $line ]] && new_suggestions+=( "$line" )
    done
  } <"$path"
  { rm -f "$path" } 2>/dev/null

  _zsh_ai_dbg "TRAPUSR1: wanted='${wanted:0:60}' buf='${BUFFER:0:60}' got=${#new_suggestions}"

  if [[ -n "$wanted" && "$wanted" == "$BUFFER" ]]; then
    _zsh_ai_suggestions=( "${new_suggestions[@]}" )
    _zsh_ai_suggestion_index=0
  else
    _zsh_ai_dbg "TRAPUSR1: buffer mismatch, discarding"
    _zsh_ai_suggestions=()
  fi

  if (( _zsh_ai_async_fd > 0 )); then
    if zmodload -e zsh/system 2>/dev/null; then
      syswrite -o $_zsh_ai_async_fd "x" 2>/dev/null
    else
      print -u $_zsh_ai_async_fd "x" 2>/dev/null
    fi
    _zsh_ai_dbg "TRAPUSR1: notified async fd=$_zsh_ai_async_fd"
  else
    _zsh_ai_dbg "TRAPUSR1: no async fd, cannot refresh"
  fi
}

# ---------------------------------------------------------------------------
# Display — inline ghost (dim suffix) + extra lines for other candidates
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
      zle -M ''
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

_zsh_ai_magic_tab() {
  emulate -L zsh
  if (( ${#_zsh_ai_suggestions} )); then
    zle zsh-ai-accept-suggestion
  else
    zle .expand-or-complete
  fi
}

# ---------------------------------------------------------------------------
# Setup — register widgets, hook, keybindings
# ---------------------------------------------------------------------------
_zsh_ai_setup_zle() {
  emulate -L zsh

  zle -N zsh-ai-accept-suggestion _zsh_ai_accept_suggestion
  zle -N zsh-ai-cycle-next _zsh_ai_cycle_next
  zle -N zsh-ai-cycle-prev _zsh_ai_cycle_prev
  zle -N zsh-ai-magic-tab _zsh_ai_magic_tab
  zle -N zsh-ai-refresh _zsh_ai_refresh_widget
  zle -N _zsh_ai_line_pre_redraw

  autoload -Uz add-zle-hook-widget 2>/dev/null || true
  if (( $+functions[add-zle-hook-widget] )); then
    add-zle-hook-widget -d line-pre-redraw _zsh_ai_line_pre_redraw 2>/dev/null
    if add-zle-hook-widget line-pre-redraw _zsh_ai_line_pre_redraw 2>/dev/null; then
      _zsh_ai_dbg "setup: hook registered via add-zle-hook-widget"
    else
      _zsh_ai_dbg "FAIL setup: add-zle-hook-widget returned error"
    fi
  else
    _zsh_ai_dbg "FAIL setup: add-zle-hook-widget not available"
    return 0
  fi

  _zsh_ai_setup_async_fd

  bindkey '^y'    zsh-ai-accept-suggestion  # Ctrl-Y: accept
  bindkey '^x^n'  zsh-ai-cycle-next         # Ctrl-X Ctrl-N: next
  bindkey '^x^p'  zsh-ai-cycle-prev         # Ctrl-X Ctrl-P: prev
  _zsh_ai_dbg "setup: keybindings bound (^Y, ^X^N, ^X^P)"
}

if [[ -o interactive ]]; then
  _zsh_ai_setup_zle
fi

zsh-ai-rebind() {
  bindkey '^y'    zsh-ai-accept-suggestion
  bindkey '^x^n'  zsh-ai-cycle-next
  bindkey '^x^p'  zsh-ai-cycle-prev
  echo "Rebound: Ctrl-Y=accept, Ctrl-X Ctrl-N=next, Ctrl-X Ctrl-P=prev"
}

# ---------------------------------------------------------------------------
# CLI commands
# ---------------------------------------------------------------------------
zsh-ai-onboard() { _zsh_ai_onboard "$@"; }

zsh-ai-status() {
  emulate -L zsh
  echo "--- zsh-ai-status ---"
  echo "Provider : ${ZSH_AI_PROVIDER:-openai}"
  echo "Base URL : $ZSH_AI_BASE_URL"
  echo "Model    : $ZSH_AI_MODEL"
  echo "API Key  : ${ZSH_AI_API_KEY:+set (${#ZSH_AI_API_KEY} chars)}${ZSH_AI_API_KEY:-NOT SET}"
  echo "Debug    : ${ZSH_AI_DEBUG:-off}"
  echo "Log file : $ZSH_AI_LOG"
  echo

  echo "Tools:"
  echo "  curl : $(command -v curl 2>/dev/null || echo MISSING)"
  echo "  jq   : $(command -v jq   2>/dev/null || echo MISSING)"
  echo

  echo "Widgets:"
  for w in zsh-ai-magic-tab zsh-ai-accept-suggestion zsh-ai-cycle-next zsh-ai-cycle-prev; do
    if zle -l "$w" >/dev/null 2>&1; then
      echo "  $w : registered"
    else
      echo "  $w : MISSING"
    fi
  done
  echo

  echo "Keybindings:"
  echo "  Ctrl-Y     : $(bindkey '^y' 2>/dev/null | command awk '{print $2}')"
  echo "  Ctrl-X N   : $(bindkey '^x^n' 2>/dev/null | command awk '{print $2}')"
  echo "  Ctrl-X P   : $(bindkey '^x^p' 2>/dev/null | command awk '{print $2}')"
  echo

  echo "Hook registration:"
  if (( $+functions[add-zle-hook-widget] )); then
    echo "  method: add-zle-hook-widget"
    local hook_list
    hook_list=$(zle -l 2>/dev/null)
    if print -r -- "$hook_list" | command grep -q 'azhw.*_zsh_ai_line_pre_redraw'; then
      echo "  _zsh_ai_line_pre_redraw: ACTIVE (azhw hook widget found)"
    elif print -r -- "$hook_list" | command grep -q '_zsh_ai_line_pre_redraw'; then
      echo "  _zsh_ai_line_pre_redraw: widget exists but hook may not be wired"
      echo "  Matching widgets:"
      print -r -- "$hook_list" | command grep '_zsh_ai_line_pre_redraw' | command sed 's/^/    /'
    else
      echo "  _zsh_ai_line_pre_redraw: NOT FOUND"
    fi
  else
    echo "  add-zle-hook-widget NOT available"
  fi

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
    echo "Full JSON:"
    print -r -- "$json" | jq . 2>/dev/null || print -r -- "$json"
    return 1
  fi

  echo "Suggestions:"
  local n=0 line
  while IFS= read -r line; do
    line=${line//$'\r'/}
    line=${line## #}
    line=${line%% #}
    [[ -n $line ]] || continue
    line=${line//\`/}
    [[ "$line" == \#* ]] && continue
    (( ++n ))
    echo "  $n) $line"
  done <<<"$choices"
  (( n )) || echo "  (none parsed)"
  echo
  echo "--- done ---"
}
