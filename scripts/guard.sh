#!/usr/bin/env bash
# Fail-closed scanning and guarded install of LOCAL agent skills.
set -euo pipefail

usage() { cat <<'HELP'
Usage:
  guard.sh status
  guard.sh scan PATH [--allow-caution]
  guard.sh install LOCAL_DIRECTORY [--agent claude|codex|both] [--allow-caution]

Default: only SAFE scans pass. CAUTION requires explicit --allow-caution,
DO_NOT_INSTALL and errors always block. Nothing is overwritten.
HELP
}

die() { printf 'Agent Shield: %s\n' "$*" >&2; exit 1; }

# SkillSpector writes reports through no-follow directory handles, so a
# symlinked TMPDIR (common on macOS and some Linux setups) would fail every scan.
tmp_root() { (cd "${TMPDIR:-/tmp}" && pwd -P) || die 'TMPDIR is not usable.'; }

# Print the `name:` value from the SKILL.md front matter (empty if absent).
frontmatter_name() {
  awk 'NR == 1 { sub(/\r$/, ""); if ($0 != "---") exit; next }
       { sub(/\r$/, "") }
       $0 == "---" { exit }
       /^name:/ { sub(/^name:[[:space:]]*/, ""); sub(/[[:space:]]+$/, "");
                  gsub(/^["\047]|["\047]$/, ""); print; exit }' "$1"
}

status() {
  if command -v reflex >/dev/null 2>&1; then
    printf '\n--- Reflex doctor ---\n'; reflex doctor || true
    printf '\n--- Reflex status ---\n'; reflex status || true
  else
    printf 'Reflex: NOT FOUND. Runtime enforcement is not confirmed.\n'
  fi
  if command -v skillspector >/dev/null 2>&1; then
    printf '\nSkillSpector: installed (%s)\n' "$(command -v skillspector)"
  else
    printf '\nSkillSpector: NOT FOUND. Pre-install scanning is unavailable.\n'
  fi
  echo 'Verify actual hook firing with your agents; Codex hooks need approval in /hooks.'
}

# Python deliberately validates the stable, documented top-level JSON schema.
# It does NOT interpret arbitrary content of findings as instructions.
assess_json() {
  local report="$1" caution="$2"
  python3 - "$report" "$caution" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        report = json.load(stream)
    assessment = report["risk_assessment"]
    recommendation = assessment["recommendation"]
    score = assessment["score"]
    assert type(score) in (int, float) and 0 <= score <= 100
    assert recommendation in ("SAFE", "CAUTION", "DO_NOT_INSTALL")
    issues = report["issues"]
    assert isinstance(issues, list)
    assert isinstance(report["skill"], dict)
except (OSError, ValueError, TypeError, KeyError, AssertionError) as exc:
    print(f"BLOCK: malformed or incomplete scanner JSON: {exc}", file=sys.stderr)
    sys.exit(2)

allow_caution = sys.argv[2] == "true"
allowed = recommendation == "SAFE" or (allow_caution and recommendation == "CAUTION")
print(f"SkillSpector: risk={score}/100 recommendation={recommendation} findings={len(issues)}")
for issue in issues[:10]:
    if not isinstance(issue, dict):
        continue
    location = issue.get("location") or {}
    if not isinstance(location, dict):
        location = {}
    print("  -", str(issue.get("id", "?"))[:30], str(issue.get("severity", "?"))[:20],
          str(location.get("file", "?"))[:160], "line", location.get("start_line", "?"))
if len(issues) > 10:
    print(f"  ... {len(issues)-10} more findings (review full scanner output manually)")
if not allowed:
    print("BLOCK: policy requires SAFE (or explicitly reviewed CAUTION).", file=sys.stderr)
    sys.exit(1)
print("PASS: policy permits this scan result; not a guarantee of safety.")
PY
}

scan_gate() {
  local target="$1" caution="$2" report scan_rc parse_rc
  command -v skillspector >/dev/null 2>&1 || die 'skillspector is not installed; refusing to proceed.'
  command -v python3 >/dev/null 2>&1 || die 'python3 is required to validate scanner JSON.'
  report="$(mktemp "$(tmp_root)/agent-shield-report.XXXXXXXX")"
  # Always remove report: output may contain sensitive paths and findings.
  # Secrets and privileged content should not be scanned without reviewing trust model.
  if skillspector scan "$target" --no-llm --fail-on-incomplete --format json --output "$report"; then
    scan_rc=0
  else
    scan_rc=$?
  fi
  if [[ ! -s "$report" ]]; then
    rm -f -- "$report"
    die "scanner did not produce a report (exit $scan_rc)."
  fi
  if assess_json "$report" "$caution"; then parse_rc=0; else parse_rc=$?; fi
  rm -f -- "$report"
  [[ "$scan_rc" == 0 && "$parse_rc" == 0 ]] || die "scan blocked (scanner exit $scan_rc, policy exit $parse_rc)."
}

# Arguments are intentionally simple: only local directories may be installed.
main() {
  if [[ $# == 0 ]]; then usage; exit 2; fi
  local action="$1"; shift
  if [[ "$action" == status ]]; then
    [[ $# == 0 ]] || { usage >&2; exit 2; }
    status; return
  fi
  if [[ "$action" == -h || "$action" == --help ]]; then usage; return; fi
  [[ "$action" == scan || "$action" == install ]] || { usage >&2; exit 2; }
  [[ $# -ge 1 ]] || { usage >&2; exit 2; }
  local target="$1"; shift
  local agent=both caution=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-caution) caution=true; shift ;;
      --agent)
        [[ "$action" == install && $# -ge 2 ]] || { usage >&2; exit 2; }
        agent="$2"; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$agent" in claude|codex|both) ;; *) die 'agent must be claude, codex, or both';; esac
  [[ -e "$target" ]] || die "input not found: $target"

  if [[ "$action" == scan ]]; then
    scan_gate "$target" "$caution"; return
  fi

  [[ -d "$target" && ! -L "$target" ]] || die 'install requires a regular local directory, not a link, archive, or URL.'
  [[ -f "$target/SKILL.md" && ! -L "$target/SKILL.md" ]] || die 'source must contain a regular SKILL.md.'
  # This is a checked immutable-ish snapshot for the scan and all target copies.
  local stage skill_name
  skill_name="$(basename "$(cd "$target" && pwd -P)")"
  [[ "$skill_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "unsupported skill directory name: $skill_name"
  stage="$(mktemp -d "$(tmp_root)/agent-shield-stage.XXXXXXXX")"
  STAGE_TO_CLEAN="$stage"
  trap '[[ -z "${STAGE_TO_CLEAN:-}" ]] || rm -rf -- "$STAGE_TO_CLEAN"' EXIT
  cp -R "$target/." "$stage/"
  if [[ -n "$(find "$stage" -type l -print -quit)" ]]; then
    die 'candidate contains symbolic links; rejecting possible escape/unscanned content.'
  fi
  # GNU and BSD cp -R both recreate FIFOs/devices/sockets; a skill never needs them.
  if [[ -n "$(find "$stage" ! -type f ! -type d -print -quit)" ]]; then
    die 'candidate contains special files (FIFO, device, or socket); rejecting.'
  fi
  # Agent Skills spec: name must match the folder. A mismatch could shadow another skill.
  local declared
  declared="$(frontmatter_name "$stage/SKILL.md")"
  [[ -z "$declared" || "$declared" == "$skill_name" ]] \
    || die "SKILL.md name '$declared' does not match directory name '$skill_name'."
  # Reject directory trees that have already been installed. Do not overwrite.
  local dests=() dest parent temp_dest
  [[ "$agent" != codex ]] && dests+=("$HOME/.claude/skills/$skill_name")
  [[ "$agent" != claude ]] && dests+=("$HOME/.agents/skills/$skill_name")
  for dest in "${dests[@]}"; do
    [[ ! -e "$dest" && ! -L "$dest" ]] || die "destination already exists; refusing overwrite: $dest"
  done
  scan_gate "$stage" "$caution"

  for dest in "${dests[@]}"; do
    parent="$(dirname "$dest")"
    mkdir -p -- "$parent"
    temp_dest="$(mktemp -d "$parent/.agent-shield.XXXXXXXX")"
    if ! cp -R "$stage/." "$temp_dest/"; then
      rm -rf -- "$temp_dest"
      die "copy failed for $dest"
    fi
    if ! mv -- "$temp_dest" "$dest"; then
      rm -rf -- "$temp_dest"
      die "install failed for $dest"
    fi
    printf 'Installed scanned skill: %s\n' "$dest"
  done
  echo 'Restart/reload the agent if the new skill does not appear.'
}

main "$@"
