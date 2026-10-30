#!/usr/bin/env bash
# Explicit opt-in setup for external dependencies and Reflex hooks.
# Installs exactly the releases pinned in pins.sh: never "latest", never npx.
set -euo pipefail

usage() { cat <<'HELP'
Usage: setup-dependencies.sh [--apply [skillspector|reflex]]
  Default: print the plan; do not install anything or change settings.
  --apply: install the pinned SkillSpector and Reflex, and install Reflex hooks
           for Claude Code + Codex in enforce mode. Name one tool to install
           only that one. REVIEW third-party upstream sources first.
HELP
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=SCRIPTDIR/pins.sh
. "$here/pins.sh"

# Explicit so earlier config/env cannot pick an LLM engine, auto-allow, or the System 2
# judge (which otherwise calls the `claude`/`codex` CLI for commands the rules miss).
REFLEX_ARGS=(--agents "claude,codex" --profile supervised --mode enforce --engine local --allow off --judge off)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/agent-shield"
SS_DIR="$DATA/skillspector-$SKILLSPECTOR_VERSION-${SKILLSPECTOR_COMMIT:0:12}"
SS_BIN="$HOME/.local/bin/skillspector"

die() { printf 'setup-dependencies: %s\n' "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing $1. Install it manually first (see README)."; }

apply=false; only=''
case "${1:-}" in
  '') [[ $# == 0 ]] || { usage >&2; exit 2; } ;;
  --apply)
    apply=true; only="${2:-}"
    [[ $# -le 2 && ( -z "$only" || "$only" == skillspector || "$only" == reflex ) ]] || { usage >&2; exit 2; } ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$apply" == false ]]; then
  cat <<PLAN
Nothing installed. With --apply, after you review the upstream projects:

SkillSpector $SKILLSPECTOR_VERSION (git commit $SKILLSPECTOR_COMMIT)
  git fetch $SKILLSPECTOR_REPO $SKILLSPECTOR_COMMIT  ->  $SS_DIR
  uv sync --locked --no-dev --no-install-project   (exact versions and hashes from its uv.lock)
  uv pip install --require-hashes -r scripts/skillspector-build.txt   (pinned build backend)
  uv pip install --no-index --no-build-isolation <checkout>   (offline build of SkillSpector)
  link $SS_BIN

Reflex $REFLEX_VERSION (npm tarball, $REFLEX_INTEGRITY)
  npm pack @ursuciprian/reflex@$REFLEX_VERSION   then verify the sha512 above
  node <verified copy>/scripts/reflex setup ${REFLEX_ARGS[*]} --dry-run
  node <verified copy>/scripts/reflex setup ${REFLEX_ARGS[*]}

Reflex setup modifies Claude Code and Codex hook configuration.
Codex also requires you to review/trust hooks in /hooks.
PLAN
  exit 0
fi

case "$(uname -s)" in
  Darwin|Linux) ;;  # Linux includes WSL. Reflex does not support native Windows.
  *) die 'This bootstrap supports macOS and Linux only.' ;;
esac
need python3

install_skillspector() {
  need git; need uv
  # Refuse to replace a skillspector we did not install (e.g. from `uv tool install`).
  if [[ -e "$SS_BIN" || -L "$SS_BIN" ]]; then
    case "$(readlink "$SS_BIN" 2>/dev/null || true)" in
      "$DATA"/skillspector-*/.venv/bin/skillspector) ;;
      *) die "$SS_BIN already exists and was not installed by Agent Shield. Remove it first (for example: uv tool uninstall skillspector)." ;;
    esac
  fi
  mkdir -p -- "$DATA" "$(dirname "$SS_BIN")"
  if [[ ! -d "$SS_DIR" ]]; then
    printf 'Fetching SkillSpector commit %s...\n' "$SKILLSPECTOR_COMMIT"
    local tmp; tmp="$(mktemp -d "$DATA/.skillspector.XXXXXXXX")"
    git -C "$tmp" init -q
    git -C "$tmp" fetch -q --depth 1 "$SKILLSPECTOR_REPO" "$SKILLSPECTOR_COMMIT" \
      || { rm -rf -- "$tmp"; die 'git fetch of the pinned commit failed.'; }
    git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD
    mv -- "$tmp" "$SS_DIR"
  fi
  [[ "$(git -C "$SS_DIR" rev-parse HEAD)" == "$SKILLSPECTOR_COMMIT" ]] || die "$SS_DIR is not at the pinned commit."
  [[ -z "$(git -C "$SS_DIR" status --porcelain --untracked-files=no)" ]] || die "$SS_DIR has local changes."
  printf 'Installing SkillSpector dependencies from its uv.lock...\n'
  # --locked fails rather than re-resolve; uv verifies every package hash in the lock.
  # The project itself is built separately so its build backend is pinned too.
  uv sync --project "$SS_DIR" --locked --no-dev --no-install-project --quiet
  local py="$SS_DIR/.venv/bin/python"
  printf 'Building SkillSpector offline with the pinned build backend...\n'
  uv pip install --python "$py" --quiet --require-hashes --no-deps --only-binary :all: \
    -r "$here/skillspector-build.txt"
  uv pip install --python "$py" --quiet --no-deps --no-index --no-build-isolation "$SS_DIR"
  # Check the version before linking, so a bad install never replaces a good link.
  local got
  got="$("$SS_DIR/.venv/bin/skillspector" --version 2>&1 | tail -n 1 || true)"
  [[ "$got" =~ (^|[^0-9.])v?${SKILLSPECTOR_VERSION//./\\.}($|[^0-9.]) ]] \
    || die "unexpected SkillSpector version output: $got"
  ln -sfn -- "$SS_DIR/.venv/bin/skillspector" "$SS_BIN"
  printf 'SkillSpector %s installed: %s\n' "$SKILLSPECTOR_VERSION" "$SS_BIN"
  [[ "$(command -v skillspector 2>/dev/null || true)" == "$SS_BIN" ]] \
    || echo "Warning: $(dirname "$SS_BIN") is not first on PATH for skillspector; add it to PATH." >&2
}

install_reflex() {
  need node; need npm
  node -e 'if (+process.versions.node.split(".")[0] < 18) process.exit(1)' || die 'Node.js 18+ required.'
  local work tgz got
  work="$(mktemp -d "${TMPDIR:-/tmp}/agent-shield-reflex.XXXXXXXX")"
  REFLEX_WORK="$work"
  trap '[[ -z "${REFLEX_WORK:-}" ]] || rm -rf -- "$REFLEX_WORK"' EXIT
  printf 'Downloading Reflex %s...\n' "$REFLEX_VERSION"
  tgz="$(cd "$work" && npm pack "@ursuciprian/reflex@$REFLEX_VERSION" --ignore-scripts --json 2>/dev/null \
         | python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["filename"])')" \
    || die 'npm pack of the pinned Reflex version failed.'
  [[ "$tgz" == *.tgz && "$tgz" != */* ]] || die "unexpected npm pack output: $tgz"
  got="sha512-$(python3 -c 'import base64, hashlib, sys
print(base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$work/$tgz")"
  [[ "$got" == "$REFLEX_INTEGRITY" ]] || die "Reflex tarball hash mismatch: $got"
  mkdir -- "$work/pkg"
  tar -xzf "$work/$tgz" -C "$work/pkg"
  got="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$work/pkg/package/package.json")"
  [[ "$got" == "$REFLEX_VERSION" ]] || die "unexpected Reflex version: $got"
  local reflex=(node "$work/pkg/package/scripts/reflex")
  printf '%s\n' 'Previewing Reflex hook changes...'
  "${reflex[@]}" setup "${REFLEX_ARGS[@]}" --dry-run
  printf '%s\n' 'Configuring Reflex in enforce mode (local engine, no auto-allow)...'
  "${reflex[@]}" setup "${REFLEX_ARGS[@]}"
  # Use the command this setup just linked, not whatever `reflex` comes first on PATH.
  local installed="$HOME/.local/bin/reflex"
  [[ -x "$installed" ]] || die "Reflex setup did not create $installed."
  got="$("$installed" version 2>/dev/null | tail -n 1 || true)"
  [[ "$got" == *"$REFLEX_VERSION"* ]] || die "installed Reflex reports an unexpected version: $got"
  "$installed" doctor
  "$installed" status
  [[ "$(command -v reflex 2>/dev/null || true)" == "$installed" ]] \
    || echo "Warning: $(dirname "$installed") is not first on PATH for reflex; add it to PATH." >&2
  printf '%s\n' 'Now restart both agents. In Codex run /hooks and trust the Reflex entries.'
}

[[ "$only" == reflex ]] || install_skillspector
[[ "$only" == skillspector ]] || install_reflex
