#!/usr/bin/env zsh
#
# zsh-ollama-completion
#   AI-powered terminal command completion using Ollama
#
# Configuration (environment variables):
#   ZSH_OLLAMA_MODEL        - Model name (default: qwen3:1.7B)
#   ZSH_OLLAMA_HOST         - Ollama API URL (default: http://localhost:11434)
#   ZSH_OLLAMA_DELAY        - Seconds of idle before triggering completion (default: 3)
#   ZSH_OLLAMA_HISTORY_SIZE - Number of history entries for context (default: 500)
#   ZSH_OLLAMA_NUM_PREDICT  - Max tokens to generate (default: 1024)
#   ZSH_OLLAMA_TEMPERATURE  - Sampling temperature (default: 0.3)
#   ZSH_OLLAMA_ENABLED      - Set to 1 to enable (default: 0, disabled)
#   ZSH_OLLAMA_ACCEPT_KEY   - Key binding to accept suggestion (default: ^F)
#   ZSH_OLLAMA_TIMEOUT      - API request timeout in seconds (default: 10)
#   ZSH_OLLAMA_THINK        - Set to 0 to disable model thinking (default: 1)
#   ZSH_OLLAMA_DEBUG        - Set to 1 to enable debug logging to stderr (default: 0)
#
# Usage:
#   export ZSH_OLLAMA_ENABLED=1
#   source zsh-ollama-completion.plugin.zsh
#   After 3 seconds of idle, a ghost-text suggestion appears in gray.
#   Press Ctrl-F to accept the suggestion. Any other key dismisses it.

# --- Internal state ---
typeset -g _ollama_suggestion=""
typeset -g _ollama_full_command=""
typeset -g _ollama_timer_pid=0
typeset -g _ollama_result_file=""
typeset -g _ollama_fd=""
typeset -g _ollama_last_buffer=""
typeset -g _ollama_initialized=0
typeset -g _ollama_spinner_frame=0
typeset -g _ollama_spinning=0
typeset -ga _ollama_spinner_chars=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

# --- Debug logging ---
_ollama_debug() {
    [[ "${ZSH_OLLAMA_DEBUG:-0}" == "1" ]] && printf '[ollama-completion] %s\n' "$*" >&2
}

# --- JSON string escaping ---
_ollama_json_escape() {
    local str="$1"
    if command -v jq &>/dev/null; then
        # jq -Rs outputs "quoted string"; strip surrounding quotes
        local quoted
        quoted=$(printf '%s' "$str" | jq -Rs .)
        printf '%s' "${quoted:1:-1}"
    else
        # Pure zsh fallback
        str="${str//\\/\\\\}"
        str="${str//\"/\\\"}"
        str="${str//$'\n'/\\n}"
        str="${str//$'\r'/\\r}"
        str="${str//$'\t'/\\t}"
        printf '%s' "$str"
    fi
}

# --- Extract content field from Ollama API response ---
_ollama_extract_content() {
    local json="$1"
    if command -v jq &>/dev/null; then
        printf '%s' "$json" | jq -r '.message.content // empty' 2>/dev/null
    elif command -v python3 &>/dev/null; then
        printf '%s' "$json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('message', {}).get('content', ''), end='')
except:
    pass
" 2>/dev/null
    else
        # Fallback: basic extraction without jq or python3
        printf '%s' "$json" | grep -oP '"content"\s*:\s*"\K([^"\\]|\\.)*' | head -1
    fi
}

# --- Strip <think>...</think> blocks (for models like qwen3) ---
_ollama_strip_think() {
    local text="$1"
    # Use sed address range to delete all lines between <think> and </think>
    printf '%s\n' "$text" | sed '/<think>/,/<\/think>/d'
}

# --- Initialization ---
_ollama_comp_init() {
    (( _ollama_initialized )) && return

    _ollama_result_file=$(mktemp "${TMPDIR:-/tmp}/ollama-comp.XXXXXX")

    local pipe_path
    pipe_path=$(mktemp -u "${TMPDIR:-/tmp}/ollama-pipe.XXXXXX")
    mkfifo "$pipe_path"
    exec {_ollama_fd}<>"$pipe_path"
    rm -f "$pipe_path"

    zle -F "$_ollama_fd" _ollama_handle_response

    _ollama_initialized=1
    _ollama_debug "initialized: fd=$_ollama_fd result_file=$_ollama_result_file"
}

# --- Cleanup ---
_ollama_comp_cleanup() {
    _ollama_kill_timer

    if [[ -n "$_ollama_fd" ]]; then
        zle -F "$_ollama_fd" 2>/dev/null
        exec {_ollama_fd}>&- 2>/dev/null
        _ollama_fd=""
    fi

    [[ -f "$_ollama_result_file" ]] && rm -f "$_ollama_result_file"

    _ollama_initialized=0
    _ollama_debug "cleaned up"
}

# --- Kill the background timer process ---
_ollama_kill_timer() {
    if (( _ollama_timer_pid > 0 )); then
        kill "$_ollama_timer_pid" 2>/dev/null
        _ollama_timer_pid=0
    fi
}

# --- Clear the displayed suggestion and spinner ---
_ollama_clear_suggestion() {
    if [[ -n "$_ollama_suggestion" || $_ollama_spinning -eq 1 ]]; then
        _ollama_suggestion=""
        _ollama_full_command=""
        _ollama_spinning=0
        _ollama_spinner_frame=0
        POSTDISPLAY=""
        # Remove region_highlight entries containing fg=8
        region_highlight=("${(@)region_highlight:#*fg=8*}")
    fi
}

# --- Async response handler (zle -F callback) ---
_ollama_handle_response() {
    local line
    if read -r line <&$1 2>/dev/null; then
        if [[ "$line" == "spin" ]]; then
            # Update spinner display
            _ollama_spinning=1
            region_highlight=("${(@)region_highlight:#*fg=8*}")
            local idx=$(( (_ollama_spinner_frame % ${#_ollama_spinner_chars[@]}) + 1 ))
            local char="${_ollama_spinner_chars[$idx]}"
            POSTDISPLAY=" $char"
            region_highlight+=("${#BUFFER} $((${#BUFFER} + ${#POSTDISPLAY})) fg=8")
            zle -R
            (( _ollama_spinner_frame++ ))
        elif [[ "$line" == "done" && -f "$_ollama_result_file" ]]; then
            # Clear spinner state
            _ollama_spinning=0
            _ollama_spinner_frame=0
            region_highlight=("${(@)region_highlight:#*fg=8*}")

            local suggestion
            suggestion=$(<"$_ollama_result_file")

            # Strip think blocks
            suggestion=$(_ollama_strip_think "$suggestion")

            # Trim leading/trailing whitespace and newlines
            suggestion="${suggestion#"${suggestion%%[! $'\n'$'\r'$'\t']*}"}"
            suggestion="${suggestion%"${suggestion##*[! $'\n'$'\r'$'\t']}"}"

            # Replace newlines with spaces for single-line display
            suggestion="${suggestion//$'\n'/ }"

            # Model returns the full command; compute ghost text to display
            local display_text="${suggestion#"$BUFFER"}"

            if [[ -n "$display_text" && "$suggestion" != "$BUFFER" ]]; then
                _ollama_debug "full command: $suggestion"
                _ollama_debug "display text: $display_text"
                _ollama_full_command="$suggestion"
                _ollama_suggestion="$display_text"
                POSTDISPLAY="${_ollama_suggestion}"
                region_highlight+=("${#BUFFER} $((${#BUFFER} + ${#_ollama_suggestion})) fg=8")
                zle -R
            else
                _ollama_debug "empty suggestion after processing"
                POSTDISPLAY=""
                zle -R
            fi
        fi
    fi
}

# --- Send completion request ---
_ollama_request_completion() {
    [[ "${ZSH_OLLAMA_ENABLED:-0}" == "0" ]] && return

    local buffer="$BUFFER"
    [[ -z "$buffer" || ${#buffer} -lt 2 ]] && return

    _ollama_kill_timer
    _ollama_clear_suggestion

    local model="${ZSH_OLLAMA_MODEL:-qwen3:1.7B}"
    local host="${ZSH_OLLAMA_HOST:-http://localhost:11434}"
    local delay="${ZSH_OLLAMA_DELAY:-3}"
    local hist_size="${ZSH_OLLAMA_HISTORY_SIZE:-500}"
    local num_predict="${ZSH_OLLAMA_NUM_PREDICT:-1024}"
    local temperature="${ZSH_OLLAMA_TEMPERATURE:-0.3}"
    local timeout="${ZSH_OLLAMA_TIMEOUT:-10}"
    local result_file="$_ollama_result_file"
    local fd="$_ollama_fd"
    local cwd="$PWD"

    _ollama_debug "requesting completion: buffer='$buffer' model=$model delay=$delay"

    {
        local spinner_pid=0
        trap 'kill $spinner_pid 2>/dev/null; exit 0' TERM INT HUP

        sleep "$delay" &
        local sleep_pid=$!
        wait $sleep_pid 2>/dev/null || exit 0

        # Start spinner
        {
            while true; do
                echo "spin" >&$fd 2>/dev/null || exit 0
                sleep 0.2
            done
        } &
        spinner_pid=$!

        # Collect recent shell history
        local history_lines
        history_lines=$(fc -l -n -"$hist_size" 2>/dev/null)

        # Build system prompt
        local system_prompt="You are a shell command autocomplete engine. The user is in: ${cwd}
Given a partial command, output the COMPLETE command that the user most likely wants to run.
Always output the full command from the beginning, including what was already typed.
Do not add explanations or markdown. Output only the command itself."

        local escaped_system escaped_buffer escaped_history
        escaped_system=$(_ollama_json_escape "$system_prompt")
        escaped_buffer=$(_ollama_json_escape "$buffer")
        escaped_history=$(_ollama_json_escape "My recent shell history:
${history_lines}")

        # Build JSON payload with few-shot examples as chat turns
        local think_param=""
        if [[ "${ZSH_OLLAMA_THINK:-1}" == "0" ]]; then
            think_param=",\"think\":false"
        fi
        local payload="{\"model\":\"${model}\",\"messages\":[{\"role\":\"system\",\"content\":\"${escaped_system}\"},{\"role\":\"user\",\"content\":\"${escaped_history}\"},{\"role\":\"assistant\",\"content\":\"Understood. I will use your history as context for completions.\"},{\"role\":\"user\",\"content\":\"git comm\"},{\"role\":\"assistant\",\"content\":\"git commit\"},{\"role\":\"user\",\"content\":\"ls -\"},{\"role\":\"assistant\",\"content\":\"ls -la\"},{\"role\":\"user\",\"content\":\"docker compo\"},{\"role\":\"assistant\",\"content\":\"docker compose up -d\"},{\"role\":\"user\",\"content\":\"${escaped_buffer}\"}],\"stream\":false${think_param},\"options\":{\"num_predict\":${num_predict},\"temperature\":${temperature}}}"

        # Call Ollama API
        _ollama_debug "calling API: ${host}/api/chat model=$model"
        local response
        response=$(curl -s --max-time "$timeout" "${host}/api/chat" -d "$payload" 2>/dev/null)

        # Stop spinner
        kill $spinner_pid 2>/dev/null
        wait $spinner_pid 2>/dev/null

        if [[ $? -eq 0 && -n "$response" ]]; then
            local content
            content=$(_ollama_extract_content "$response")
            _ollama_debug "API response content: $content"

            if [[ -n "$content" ]]; then
                printf '%s' "$content" > "$result_file"
                echo "done" >&$fd 2>/dev/null
            else
                _ollama_debug "API returned empty content"
            fi
        else
            _ollama_debug "API call failed or returned empty response"
        fi
    } &!

    _ollama_timer_pid=$!
}

# --- ZLE hook: detect buffer changes ---
_ollama_line_pre_redraw() {
    [[ "${ZSH_OLLAMA_ENABLED:-0}" == "0" ]] && return
    (( ! _ollama_initialized )) && return

    if [[ "$BUFFER" != "$_ollama_last_buffer" ]]; then
        _ollama_last_buffer="$BUFFER"
        if [[ -n "$BUFFER" ]]; then
            _ollama_request_completion
        else
            _ollama_kill_timer
            _ollama_clear_suggestion
        fi
    fi
}

# --- Ctrl-F: accept suggestion or forward-char ---
_ollama_accept_or_forward_char() {
    if [[ -n "$_ollama_suggestion" ]]; then
        _ollama_debug "accepted: $_ollama_full_command"
        BUFFER="$_ollama_full_command"
        CURSOR=${#BUFFER}
        _ollama_clear_suggestion
        _ollama_last_buffer="$BUFFER"
    else
        zle forward-char
    fi
}

# --- Plugin setup ---

# Register widget
zle -N _ollama_accept_or_forward_char

# Bind accept key (default: Ctrl-F)
bindkey "${ZSH_OLLAMA_ACCEPT_KEY:-'^F'}" _ollama_accept_or_forward_char

# Register line-pre-redraw hook (requires zsh 5.3+)
autoload -Uz add-zle-hook-widget
add-zle-hook-widget line-pre-redraw _ollama_line_pre_redraw

# Initialize on first prompt
_ollama_precmd_init() {
    _ollama_comp_init
    add-zsh-hook -d precmd _ollama_precmd_init
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _ollama_precmd_init

# Cleanup on shell exit
add-zsh-hook zshexit _ollama_comp_cleanup
