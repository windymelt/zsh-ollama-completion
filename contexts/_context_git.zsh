#!/usr/bin/env zsh
# Context provider: git repository info
# Environment: _OLLAMA_CWD

local cwd="${_OLLAMA_CWD:-.}"

if git -C "$cwd" rev-parse --is-inside-work-tree &>/dev/null; then
    local branch
    branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
    local git_status
    git_status=$(git -C "$cwd" status --short 2>/dev/null)
    printf 'Git info:\nBranch: %s\nStatus:\n%s' "$branch" "$git_status"
fi
