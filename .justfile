#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod bootstrap "bootstrap"
mod kube "kubernetes"
mod manage "manage"
mod talos "talos"

[private]
default:
    just -l

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

# The dotfiles alias `op` to `op.exe` on WSL, but aliases never reach a recipe's shell.
# op.exe is on the WSL PATH (the alias has no path), so pick it the same way here; the
# Windows build writes CRLF.
[private]
template file *args:
    op="$(command -v op.exe || command -v op)" || { just log fatal "1Password CLI not found"; exit 1; }; \
    minijinja-cli "{{ file }}" {{ args }} | "$op" inject | tr -d '\r'
