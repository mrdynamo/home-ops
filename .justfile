#!/usr/bin/env -S just --justfile

set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod bootstrap "bootstrap"
mod kube "kubernetes"
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

# Written via a 0600 temp file, so a failed render never clobbers the existing output.
# Render a template to its name without the `.j2` suffix (`just render cloudflare-tunnel.json.j2`)
render file:
    dest="{{ file }}"; dest="${dest%.j2}"; \
    [[ "$dest" != "{{ file }}" ]] || { just log fatal "Not a .j2 template" file "{{ file }}"; exit 1; }; \
    tmp="$(mktemp "$dest.XXXXXX")"; \
    just template "{{ file }}" > "$tmp" && mv "$tmp" "$dest" || { rm -f "$tmp"; exit 1; }; \
    just log info "Rendered" file "$dest"
