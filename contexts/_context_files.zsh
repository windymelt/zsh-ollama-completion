#!/usr/bin/env zsh
# Context provider: file listing of current directory
# Environment: _OLLAMA_CWD

local cwd="${_OLLAMA_CWD:-.}"
local file_list
file_list=$(ls -1 "$cwd" 2>/dev/null | head -100)

if [[ -n "$file_list" ]]; then
    printf 'Files in current directory:\n%s' "$file_list"
fi
