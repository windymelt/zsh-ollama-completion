#!/usr/bin/env zsh
# Context provider: recent shell history
# Environment: _OLLAMA_HIST_SIZE

local hist_size="${_OLLAMA_HIST_SIZE:-500}"
local history_lines
history_lines=$(fc -l -n -"$hist_size" 2>/dev/null)

if [[ -n "$history_lines" ]]; then
    printf 'My recent shell history:\n%s' "$history_lines"
fi
