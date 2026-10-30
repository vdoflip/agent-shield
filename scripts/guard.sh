#!/usr/bin/env bash
# Fail-closed scanning and guarded install of LOCAL agent skills.
set -euo pipefail

usage() { cat <<'HELP'
Usage:
  guard.sh status
  guard.sh scan PATH [--allow-caution] [--strict]
  guard.sh install LOCAL_DIRECTORY [--agent claude|codex|both] [--allow-caution] [--strict]

Default: only SAFE scans pass. CAUTION requires explicit --allow-caution,
DO_NOT_INSTALL and errors always block. Nothing is overwritten.

Trusted sources (decided by install location, never by file contents):
  Anthropic     skills synced from claude.ai (~/.claude/skills/synced, manifest source anthropic*)
  OpenAI        Codex built-in system skills (~/.codex/skills/.system)
  Agent Shield  this tool's own files
For these, risk score and incomplete analysis do not block. Hard findings still
block: any CRITICAL finding, malware/webshell/cryptominer YARA matches (YR1-YR3),
and dependencies with known HIGH/CRITICAL vulnerabilities (SC4). Scanner errors
always block. --strict ignores the trusted list.
HELP
}

die() { printf 'Agent Shield: %s\n' "$*" >&2; exit 1; }

SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

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

real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Print "Publisher (where)" when PATH is a trusted install location, else nothing.
# Trust comes only from where the skill lives and its vendor's own metadata there.
trusted_source() {
  local real parent name dir
  real="$(real_dir "$1")" || return 0
  parent="$(dirname "$real")"; name="$(basename "$real")"

  # Agent Shield: the same SKILL.md and scripts as the copy running right now.
  if [[ "$name" == agent-shield && -f "$real/SKILL.md" ]] \
     && cmp -s "$real/SKILL.md" "$SELF_ROOT/SKILL.md" \
     && diff -r "$real/scripts" "$SELF_ROOT/scripts" >/dev/null 2>&1; then
    echo 'Agent Shield (this tool)'; return
  fi

  # OpenAI: Codex unpacks its built-in skills here and leaves a marker file.
  dir="$(real_dir "${CODEX_HOME:-$HOME/.codex}/skills/.system")" || dir=''
  if [[ -n "$dir" && "$parent" == "$dir" && -f "$dir/.codex-system-skills.marker" ]]; then
    echo 'OpenAI (Codex built-in system skill)'; return
  fi

  # Anthropic: Claude Code syncs account skills into synced/<bucket>/ with a manifest.
  dir="$(real_dir "$HOME/.claude/skills/synced")" || dir=''
  if [[ -n "$dir" && "$(dirname "$parent")" == "$dir" && -f "$parent/manifest.json" ]] \
     && python3 - "$parent/manifest.json" "$name" 2>/dev/null <<'PY'
import json, sys
skills = json.load(open(sys.argv[1], encoding="utf-8")).get("skills", [])
sys.exit(0 if any(isinstance(s, dict) and s.get("skillId") == sys.argv[2]
                  and s.get("source") in ("anthropic", "anthropic-example")
                  for s in skills) else 1)
PY
  then
    echo 'Anthropic (claude.ai account sync)'; return
  fi

  # Local additions: LABEL=DIRECTORY lines; skills directly inside DIRECTORY are trusted.
  # The file is ignored unless it is yours and only you can write it.
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/agent-shield/trusted-dirs"
  [[ -f "$conf" ]] || return 0
  python3 - "$conf" "$parent" <<'PY' || true
import os, stat, sys
conf, parent = sys.argv[1], sys.argv[2]
st = os.stat(conf, follow_symlinks=False)
if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
    print(f"Agent Shield: ignoring {conf}: must be a regular file you own, not group/world-writable.",
          file=sys.stderr)
    sys.exit(0)
for line in open(conf, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    label, directory = (part.strip() for part in line.split("=", 1))
    directory = os.path.expanduser(directory)
    if label and os.path.isdir(directory) and os.path.realpath(directory) == parent:
        print(f"{label[:60]} (local trusted directory {directory})")
        break
PY
}

status() {
  # shellcheck source=SCRIPTDIR/pins.sh
  . "$SELF_ROOT/scripts/pins.sh"
  if command -v reflex >/dev/null 2>&1; then
    printf 'Reflex: %s (pinned %s)\n' "$(reflex version 2>/dev/null | tail -n 1)" "$REFLEX_VERSION"
    printf '\n--- Reflex doctor ---\n'; reflex doctor || true
    printf '\n--- Reflex status ---\n'; reflex status || true
  else
    printf 'Reflex: NOT FOUND. Runtime enforcement is not confirmed.\n'
  fi
  if command -v skillspector >/dev/null 2>&1; then
    printf '\nSkillSpector: %s at %s (pinned v%s)\n' "$(skillspector --version 2>/dev/null | tail -n 1)" \
      "$(command -v skillspector)" "$SKILLSPECTOR_VERSION"
  else
    printf '\nSkillSpector: NOT FOUND. Pre-install scanning is unavailable.\n'
  fi
  echo 'Verify actual hook firing with your agents; Codex hooks need approval in /hooks.'
}

# Python deliberately validates the stable, documented top-level JSON schema.
# It does NOT interpret arbitrary content of findings as instructions.
assess_json() {
  local report="$1" caution="$2" trusted="$3"
  python3 - "$report" "$caution" "$trusted" <<'PY'
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
    assert report.get("execution_successful", True) is not False, "scanner reported a failed run"
except (OSError, ValueError, TypeError, KeyError, AssertionError) as exc:
    print(f"BLOCK: malformed or incomplete scanner JSON: {exc}", file=sys.stderr)
    sys.exit(2)

def where(issue):
    location = issue.get("location") if isinstance(issue.get("location"), dict) else {}
    return f'{str(location.get("file", "?"))[:160]} line {location.get("start_line", "?")}'

# Findings that block even a trusted source: plainly malicious or known-vulnerable.
def hard(issue):
    rule, severity = str(issue.get("id", "")), str(issue.get("severity", "")).upper()
    return (severity == "CRITICAL" or rule in ("YR1", "YR2", "YR3")
            or (rule == "SC4" and severity in ("HIGH", "CRITICAL")))

issues = [i for i in issues if isinstance(i, dict)]
hard_issues = [i for i in issues if hard(i)]
allow_caution, trusted = sys.argv[2] == "true", sys.argv[3]

print(f"SkillSpector: risk={score}/100 recommendation={recommendation} findings={len(issues)}")
for issue in issues[:10]:
    print("  -", str(issue.get("id", "?"))[:30], str(issue.get("severity", "?"))[:20], where(issue))
if len(issues) > 10:
    print(f"  ... {len(issues)-10} more findings (review full scanner output manually)")

if trusted:
    print(f"Trusted source: {trusted}. Score and incomplete analysis do not block; hard findings do.")
    if hard_issues:
        for issue in hard_issues[:10]:
            print("  HARD:", str(issue.get("id", "?"))[:30], str(issue.get("severity", "?"))[:20],
                  where(issue), file=sys.stderr)
        print("BLOCK: trusted source has critical, malware, or known-vulnerable findings.", file=sys.stderr)
        sys.exit(1)
    print("PASS: trusted source with no hard findings; not a guarantee of safety.")
    sys.exit(0)

if not (recommendation == "SAFE" or (allow_caution and recommendation == "CAUTION")):
    print("BLOCK: policy requires SAFE (or explicitly reviewed CAUTION).", file=sys.stderr)
    sys.exit(1)
print("PASS: policy permits this scan result; not a guarantee of safety.")
PY
}

scan_gate() {
  local target="$1" caution="$2" trusted="$3" report scan_rc parse_rc
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
  if assess_json "$report" "$caution" "$trusted"; then parse_rc=0; else parse_rc=$?; fi
  rm -f -- "$report"
  # SkillSpector exit 1 = risk > 50 or incomplete analysis; 2+ = error.
  # A trusted source may pass with exit 1; errors never pass.
  if [[ "$parse_rc" == 0 && ( "$scan_rc" == 0 || ( -n "$trusted" && "$scan_rc" == 1 ) ) ]]; then
    return 0
  fi
  die "scan blocked (scanner exit $scan_rc, policy exit $parse_rc)."
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
  local agent=both caution=false strict=false trusted=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allow-caution) caution=true; shift ;;
      --strict) strict=true; shift ;;
      --agent)
        [[ "$action" == install && $# -ge 2 ]] || { usage >&2; exit 2; }
        agent="$2"; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$agent" in claude|codex|both) ;; *) die 'agent must be claude, codex, or both';; esac
  [[ -e "$target" ]] || die "input not found: $target"
  [[ "$strict" == true ]] || trusted="$(trusted_source "$target")"

  if [[ "$action" == scan ]]; then
    # SkillSpector refuses symlinked inputs; scan what the link points to (what agents load).
    local resolved
    resolved="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$target")"
    [[ "$resolved" == "$target" ]] || printf 'Scanning link target: %s\n' "$resolved"
    scan_gate "$resolved" "$caution" "$trusted"; return
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
  # The staged copy is what gets scanned and installed; trust came from the source location.
  scan_gate "$stage" "$caution" "$trusted"

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
