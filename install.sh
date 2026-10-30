#!/usr/bin/env bash
# Install only this meta-skill; DOES NOT install dependencies or change hooks.
set -euo pipefail
if [[ $# -gt 1 || ( $# == 1 && "$1" != --replace ) ]]; then
  echo 'Usage: bash install.sh [--replace]' >&2; exit 2
fi
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Only these are installed; .git, tests, and other repo files stay behind.
items=(SKILL.md README.md LICENSE scripts)
[[ -f "$src/SKILL.md" ]] || { echo "Missing $src/SKILL.md" >&2; exit 2; }
for item in "${items[@]}"; do
  [[ ! -e "$src/$item" ]] && continue
  [[ ! -L "$src/$item" && -z "$(find "$src/$item" -type l -print -quit)" ]] \
    || { echo "Refusing symlink in $item." >&2; exit 2; }
done

dests=("$HOME/.claude/skills/agent-shield" "$HOME/.agents/skills/agent-shield")
for dest in "${dests[@]}"; do
  if [[ ( -e "$dest" || -L "$dest" ) && "${1:-}" != --replace ]]; then
    echo "Already installed: $dest (use --replace after reviewing changes)" >&2; exit 1
  fi
done
# Checked before anything is written, so a refusal leaves no partial install.
backups="$HOME/.agent-shield-backups"
[[ ! -L "$backups" ]] || { echo 'Refusing symlinked ~/.agent-shield-backups.' >&2; exit 2; }
for dest in "${dests[@]}"; do
  parent="$(dirname "$dest")"
  mkdir -p -- "$parent"
  staged="$(mktemp -d "$parent/.agent-shield-install.XXXXXXXX")"
  for item in "${items[@]}"; do
    [[ -e "$src/$item" ]] && cp -R "$src/$item" "$staged/"
  done
  if [[ -e "$dest" || -L "$dest" ]]; then
    # Back up outside the skills folder, or the agent would load the backup as a second skill.
    [[ -d "$backups" ]] || mkdir -m 700 -- "$backups"
    backup="$backups/$(basename "$(dirname "$parent")")-agent-shield.$(date +%Y%m%d-%H%M%S).$$"
    mv -- "$dest" "$backup"
    echo "Backup: $backup"
  fi
  mv -- "$staged" "$dest"
  echo "Installed: $dest"
done
printf '\nNext: review dependencies, then optionally run:\n  bash ~/.claude/skills/agent-shield/scripts/setup-dependencies.sh\n  bash ~/.claude/skills/agent-shield/scripts/setup-dependencies.sh --apply\n'
