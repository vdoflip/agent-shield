#!/usr/bin/env bash
# Explicit opt-in setup for external dependencies and Reflex hooks.
set -euo pipefail

usage() { cat <<'HELP'
Usage: setup-dependencies.sh [--apply]
  Default: print commands; do not install anything or change settings.
  --apply: install SkillSpector and install Reflex hooks for Claude Code + Codex
           in enforce mode. REVIEW third-party upstream sources first.
HELP
}

# Pinned to the versions whose CLI/JSON contract guard.sh was checked against.
# Override only after reviewing the new upstream release.
SKILLSPECTOR_REF="${SKILLSPECTOR_REF:-v2.13.2}"
REFLEX_VERSION="${REFLEX_VERSION:-0.18.2}"
SKILLSPECTOR_SRC="git+https://github.com/NVIDIA/skillspector.git@${SKILLSPECTOR_REF}"
REFLEX_PKG="@ursuciprian/reflex@${REFLEX_VERSION}"
# Explicit so earlier Reflex config/env cannot switch to an LLM engine or auto-allow.
REFLEX_ARGS=(--agents claude,codex --mode enforce --engine local --allow off)

apply=false
if [[ $# -gt 1 ]]; then usage; exit 2; fi
case "${1:-}" in
  '') ;;
  --apply) apply=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$apply" == false ]]; then
  cat <<PLAN
Nothing installed. Proposed commands, after you review the upstream projects:
  uv tool install ${SKILLSPECTOR_SRC}
  npx --yes ${REFLEX_PKG} setup ${REFLEX_ARGS[*]} --dry-run
  npx --yes ${REFLEX_PKG} setup ${REFLEX_ARGS[*]}
  reflex doctor
  reflex status

Reflex setup can modify Claude Code and Codex hook configuration.
Codex also requires you to review/trust hooks in /hooks.
PLAN
  exit 0
fi

case "$(uname -s)" in
  Darwin|Linux) ;;  # Linux includes WSL. Reflex does not support native Windows.
  *) echo 'This bootstrap supports macOS and Linux only.' >&2; exit 2 ;;
esac
for cmd in node npx uv python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing $cmd. Install it manually first (see README)." >&2; exit 2; }
done
node -e 'if (+process.versions.node.split(".")[0] < 18) process.exit(1)' || { echo 'Node.js 18+ required.' >&2; exit 2; }

printf '%s\n' 'Installing SkillSpector from its upstream Git repository...'
uv tool install "$SKILLSPECTOR_SRC"
printf '%s\n' 'Previewing Reflex hook changes...'
npx --yes "$REFLEX_PKG" setup "${REFLEX_ARGS[@]}" --dry-run
printf '%s\n' 'Configuring Reflex in enforce mode (local engine, no auto-allow)...'
npx --yes "$REFLEX_PKG" setup "${REFLEX_ARGS[@]}"

if command -v reflex >/dev/null 2>&1; then
  reflex doctor
  reflex status
else
  echo 'Reflex/SkillSpector not on PATH. Add ~/.local/bin to PATH (or run: uv tool update-shell), then run reflex doctor/status.' >&2
fi
printf '%s\n' 'Now restart both agents. In Codex run /hooks and trust the Reflex entries.'
