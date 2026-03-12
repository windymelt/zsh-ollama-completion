#!/usr/bin/env zsh
# Context provider: OS information

local os_info
os_info=$(uname -s -r -m 2>/dev/null)

if [[ -n "$os_info" ]]; then
    printf 'OS: %s' "$os_info"
fi
