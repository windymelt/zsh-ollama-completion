# zsh-ollama-completion

AI-powered terminal command completion for zsh using [Ollama](https://ollama.com/).

After a configurable idle period (default: 3 seconds), the plugin sends your current input and recent shell history to a local Ollama model and displays a ghost-text suggestion in gray. Press `Ctrl-F` to accept it.

## Prerequisites

- zsh 5.3+
- [Ollama](https://ollama.com/) running locally (or on a reachable host)
- An Ollama model pulled (e.g. `ollama pull qwen3:1.7B`)
- `curl`
- `jq` or `python3` (for JSON parsing; falls back gracefully)

## Installation

### Manual

```zsh
git clone https://github.com/windymelt/zsh-ollama-completion.git
```

Add to your `.zshrc`:

```zsh
export ZSH_OLLAMA_ENABLED=1
source /path/to/zsh-ollama-completion/zsh-ollama-completion.plugin.zsh
```

### zinit

```zsh
export ZSH_OLLAMA_ENABLED=1
zinit light windymelt/zsh-ollama-completion
```

### Oh My Zsh

Clone into the custom plugins directory:

```zsh
git clone https://github.com/windymelt/zsh-ollama-completion.git \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-ollama-completion
```

Add to your `.zshrc` (before `source $ZSH/oh-my-zsh.sh`):

```zsh
export ZSH_OLLAMA_ENABLED=1
plugins=(... zsh-ollama-completion)
```

## Configuration

The plugin is **disabled by default**. Set `ZSH_OLLAMA_ENABLED=1` to enable it.

All configuration is done via environment variables. Set them in your `.zshrc` before sourcing the plugin.

| Variable | Default | Description |
|---|---|---|
| `ZSH_OLLAMA_ENABLED` | `0` | Set to `1` to enable the plugin |
| `ZSH_OLLAMA_MODEL` | `qwen3:1.7B` | Ollama model name |
| `ZSH_OLLAMA_HOST` | `http://localhost:11434` | Ollama API URL |
| `ZSH_OLLAMA_DELAY` | `3` | Seconds of idle before triggering completion |
| `ZSH_OLLAMA_HISTORY_SIZE` | `500` | Number of history entries sent as context |
| `ZSH_OLLAMA_NUM_PREDICT` | `1024` | Max tokens to generate |
| `ZSH_OLLAMA_TEMPERATURE` | `0.3` | Sampling temperature |
| `ZSH_OLLAMA_TIMEOUT` | `10` | API request timeout in seconds |
| `ZSH_OLLAMA_ACCEPT_KEY` | `^F` | Key binding to accept suggestion |
| `ZSH_OLLAMA_THINK` | `1` | Set to `0` to disable model thinking (faster, lower quality) |
| `ZSH_OLLAMA_DEBUG` | `0` | Set to `1` to enable debug logging to stderr |
| `ZSH_OLLAMA_EXTRA_CONTEXT_DIR` | _(none)_ | Path to directory with extra `_context_*.zsh` scripts |

### Example `.zshrc`

```zsh
export ZSH_OLLAMA_ENABLED=1
export ZSH_OLLAMA_MODEL="qwen3:1.7B"
export ZSH_OLLAMA_DELAY=3
export ZSH_OLLAMA_HOST="http://localhost:11434"
source /path/to/zsh-ollama-completion/zsh-ollama-completion.plugin.zsh
```

## Usage

1. Start typing a command.
2. Pause for 3 seconds (or your configured delay).
3. A gray ghost-text suggestion appears after your cursor.
4. Press `Ctrl-F` to accept the suggestion.
5. Type anything else to dismiss it.

When no suggestion is displayed, `Ctrl-F` behaves as the default `forward-char`.

## Context Providers

The plugin uses a context provider architecture to gather information sent to the LLM. Each provider is a small zsh script in the `contexts/` directory whose filename starts with `_context_`.

### Default providers

| Script | Description |
|---|---|
| `_context_history.zsh` | Recent shell history |
| `_context_files.zsh` | File listing of the current directory |
| `_context_git.zsh` | Git branch and status (only inside a git repo) |
| `_context_os.zsh` | OS name, version, and architecture |

### Custom context providers

Create a directory with custom `_context_*.zsh` scripts and point `ZSH_OLLAMA_EXTRA_CONTEXT_DIR` to it:

```zsh
export ZSH_OLLAMA_EXTRA_CONTEXT_DIR="$HOME/.config/zsh-ollama-contexts"
```

Each script receives the following environment variables:

- `_OLLAMA_CWD` -- the user's current working directory
- `_OLLAMA_HIST_SIZE` -- configured history size

A provider script should print its context text to stdout. If it produces no output, the context is silently skipped.

Example custom provider (`_context_kubectl.zsh`):

```zsh
#!/usr/bin/env zsh
local ctx
ctx=$(kubectl config current-context 2>/dev/null)
if [[ -n "$ctx" ]]; then
    printf 'Kubernetes context: %s' "$ctx"
fi
```

## How It Works

- On each buffer change, the plugin starts a background timer.
- After the configured delay, it sends the current input and recent shell history to the Ollama `/api/chat` endpoint.
- The response is displayed as ghost text using zsh's `POSTDISPLAY` with dimmed coloring (`fg=8`).
- Communication between the background process and zle uses a named pipe and `zle -F` for fully asynchronous operation.
- Models that emit `<think>...</think>` blocks (e.g. qwen3) are handled automatically by stripping those blocks from the output.

## License

BSD 3-Clause License. See [LICENSE](LICENSE) for details.
