# Agent Shield — meta-skill for Claude Code and Codex (macOS & Linux)

A portable `SKILL.md` + local shell helpers that coordinate:

1. **Reflex** (https://github.com/ursuciprian/reflex): an independent runtime hook-based gate for tool calls and prompt-injection-bearing content.
2. **NVIDIA SkillSpector** (https://github.com/NVIDIA/skillspector): a pre-install scanner for skills.

**Important:** This meta-skill does not magically attach to every operation. The actual runtime gate is Reflex's separately configured hooks. The scan gate applies when you use this package's `guard.sh install`, not when you manually copy a skill into place or use another installer.

Supported platforms: macOS and Linux (including WSL). Native Windows is not supported (Reflex does not support it).

## Disclaimer

**Agent Shield reduces risk; it does not make an agent safe.** It is provided as-is, with no warranty. A pass from either tool means "no known bad pattern was found", not "this is safe". Keep your agent's sandbox, permission prompts, least-privilege credentials, and network controls switched on. Agent Shield is meant to sit on top of them, not replace them.

Checked against SkillSpector `v2.13.2` and Reflex `0.18.2` (October 2026); `setup-dependencies.sh` installs exactly those (see [Pinned versions](#pinned-versions)). Newer upstream releases may behave differently.

### What it covers

| Area | Protection | How strong |
|---|---|---|
| Installing a skill **through `guard.sh install`** | Copies the skill to a private staging folder, rejects symlinks, special files, and a `name:` that differs from the folder, scans that exact copy with SkillSpector, and installs only that copy. Never overwrites an existing skill. | Blocking. Fails closed on scanner errors, bad/missing reports, and incomplete analysis. |
| Skill scan verdicts | `SAFE` (score 0–20) passes; `CAUTION` (21–50) needs `--allow-caution` from a human; `DO_NOT_INSTALL` (51+) always blocks. A self-shipped suppression baseline in the skill is ignored. | Static analysis only: pattern rules, YARA rules, Python AST and taint checks, dependency CVE lookups. |
| Trusted vendors (Anthropic, OpenAI) and Agent Shield itself | Recognised by install location (see [Trusted sources](#trusted-sources)). Score and incomplete analysis don't block; CRITICAL findings, malware/webshell/cryptominer matches, and dependencies with known HIGH/CRITICAL vulnerabilities still do. | Blocking for those hard findings only. Scanner errors still block. |
| Commands the agent runs (Claude Code) | Reflex checks `Bash`, `Task`/`Agent`, `Edit`/`Write`/`MultiEdit`/`NotebookEdit`, and MCP tool calls **before** they run, and can ask you or deny. | Blocking in `enforce` mode. If Reflex itself errors, it asks you. |
| Commands the agent runs (Codex) | Same gate on `Bash`, `spawn_agent`, `apply_patch`, MCP tools. | Blocking once you trust the hooks in `/hooks`. |
| Prompt injection in tool results (Claude Code) | After `WebFetch`, `WebSearch`, `Read` of files outside your project, `Bash` that fetches remote content, and MCP results, Reflex scans the text. **Warn** adds a note for the model; **block** cuts the offending text out of the result. Marks the session as tainted, so later commands get stricter checks. | Pattern-based (local engine). Runs after the tool, see below. |
| Prompt injection in tool results (Codex) | Same scan on `Bash` and MCP results. | Same. |
| Credentials pasted into your prompt | Reflex blocks the prompt before the model sees it. | Pattern-based. |
| Manual checks | `reflex scan <file>` (exit 0 pass / 1 warn / 2 block) and `reflex check '<command>'`. | Advisory. |

### What it does not cover

- **Skills installed any other way.** Copying a folder into `~/.claude/skills`, `git clone`, plugin marketplaces, `npx skills add`, or another agent installing something are not scanned. A skill cannot force itself to run, so the agent may also simply not use this one.
- **Anything already installed.** Existing skills, plugins, MCP servers, `CLAUDE.md`/`AGENTS.md` files, and hooks are not audited. Run `guard.sh scan` on them yourself if you want a check.
- **Updates.** A skill that passed today can change on disk later. Nothing re-scans it.
- **Malicious behaviour that looks normal.** Static analysis has false negatives: obfuscated code, logic split across files, code downloaded at run time, or harmful instructions phrased harmlessly can pass. It also has false positives.
- **Prompt injection, fully.** The injection guard is pattern-based. New or subtle wording can get through. It runs *after* the tool returns, so with a warn (or with the Claude Code plugin install, even a block) the text still reaches the model, with a note attached.
- **Tools Reflex does not hook.** In Claude Code: `Read` inside your project, `Glob`, `Grep`, `Skill`, `WebFetch`/`WebSearch` *requests* (only their results are scanned), and other built-in tools are not gated before running. Codex's hosted web search is not hooked at all. Claude Desktop, Cursor, and other hosts without hooks get advisory checks only (via `reflex mcp`).
- **Hook timeouts or a broken install.** If a Reflex hook times out (10–15 s), or `node` or the Reflex files are missing, Claude Code and Codex **let the action run**. `guard.sh status` and `reflex doctor` help you notice this; they do not prevent it.
- **Shadow mode.** If Reflex is in `shadow` mode (its default when set up without `--mode enforce`), it only logs. `setup-dependencies.sh` uses `enforce`.
- **A determined local attacker.** A process running as your user can edit hooks, settings, the staging folder during a scan, or the installed skill afterwards. It could also drop a skill into a trusted location (the claude.ai sync folder or `~/.codex/skills/.system`) to get the relaxed policy. Reflex adds permission rules that ask before editing its own files, but that is not tamper-proof.
- **Privacy.** With `--no-llm`, skill contents are not sent to an LLM, but SkillSpector sends dependency names and versions to OSV.dev. Reflex's local engine makes no network calls. Reflex's `jev` engine, its `autonomous` profile, and its "System 2" judge *do* send commands and text to an external model. The judge is **on by default** in Reflex's normal profile whenever a `claude` or `codex` CLI is installed; this setup turns all three off explicitly (`--engine local --judge off`).
- **Supply chain of the tools themselves.** Reflex and SkillSpector are third-party code that runs on your machine with your permissions. Pinning to an exact commit, lockfile, and tarball hash means you get the code that was reviewed, not whatever is newest, but it does not make that code correct. Review it before `--apply`.
- **Native Windows.**

## Prerequisites

| Tool | Needed for | macOS | Linux |
|---|---|---|---|
| `bash`, `python3` (any 3.x) | `guard.sh`, JSON validation | preinstalled / `brew install python` | distro package (`python3`) |
| `node` 18+ and `npx` | Reflex | `brew install node` | distro package, `mise`, `nvm`, or nodejs.org |
| `uv` | SkillSpector (it fetches its own Python 3.12+ if needed) | `brew install uv` | `pacman -S uv`, `pipx install uv`, or `curl -LsSf https://astral.sh/uv/install.sh \| sh` |

Both `uv tool install` and Reflex put binaries in `~/.local/bin`. Make sure it is on `PATH` (`uv tool update-shell` adds it).

## Installation

1. Clone the repository and review `install.sh`, `SKILL.md`, and the scripts:

   ```bash
   git clone https://github.com/vdoflip/agent-shield.git
   cd agent-shield
   ```

2. Install the skill:

   ```bash
   bash install.sh
   ```

   This copies only `SKILL.md`, `README.md`, `LICENSE`, and `scripts/` (the *meta-skill only*, no third-party packages) into:
   - `~/.claude/skills/agent-shield/` (Claude Code)
   - `~/.agents/skills/agent-shield/` (Codex)

   Existing installations are not overwritten. To update, review the new files and run `bash install.sh --replace` (backs up existing folders first).

3. To preview third-party tool installation and hook changes:

   ```bash
   bash ~/.claude/skills/agent-shield/scripts/setup-dependencies.sh
   ```

4. If you agree with the publisher's source, package-install risks, and proposed hook changes, apply:

   ```bash
   bash ~/.claude/skills/agent-shield/scripts/setup-dependencies.sh --apply
   ```

   This installs the exact versions in `scripts/pins.sh` (see [Pinned versions](#pinned-versions)) and configures Reflex for Claude Code and Codex in **enforce** mode with the local engine, no auto-allow, and no LLM judge (`--engine local --allow off --judge off`). Third-party install commands run only with `--apply`. `--apply skillspector` or `--apply reflex` installs just one of them.

   Requires `git`, `uv`, `node` 18+, `npm`, and `python3`. If you already have a `skillspector` from `uv tool install`, remove it first (`uv tool uninstall skillspector`); the script will not overwrite it.

### Pinned versions

`scripts/pins.sh` is the single source of truth. Nothing is resolved to "latest":

| Tool | What is pinned | How it is enforced |
|---|---|---|
| SkillSpector `2.13.2` | Git commit `abd82935…` (tag `v2.13.2`) and its `uv.lock` (158 packages) | Fetches that commit by hash and checks `HEAD`; `uv sync --locked` refuses to re-resolve and verifies every package's sha256. Installed under `~/.local/share/agent-shield/` and linked to `~/.local/bin/skillspector`. |
| Reflex `0.18.2` | npm tarball sha512 (built from git commit `b9ccab1`, tag `v0.18.2`) | Downloads with `npm pack`, checks the sha512 and version, and runs setup from that verified copy, never through `npx`. Reflex has no npm dependencies and no install scripts. |

`guard.sh status` shows the installed versions next to the pinned ones. To upgrade, review the new release and update every value in `pins.sh` together.

5. Restart Codex CLI, run `/hooks`, review, and trust the Reflex entries. Claude Code picks up new skills without a restart, but restart it once so the new Reflex hooks load; `/hooks` shows them. Then verify:

   ```bash
   bash ~/.claude/skills/agent-shield/scripts/guard.sh status
   ```

### Claude Code notes

- Claude Code expands `${CLAUDE_SKILL_DIR}` in `SKILL.md`, so the agent gets the real script path without guessing.
- `guard.sh install` writes outside the project (`~/.claude/skills`, `~/.agents/skills`). With Claude Code's sandbox or default permissions you'll get an approval prompt. That is intended; approve it only after reading the scan result.
- To skip the prompt for read-only checks only, you can allow them in `~/.claude/settings.json`, e.g. `"Bash(bash ~/.claude/skills/agent-shield/scripts/guard.sh status)"` and `"Bash(bash ~/.claude/skills/agent-shield/scripts/guard.sh scan *)"`. Don't pre-approve `install` or `--allow-caution`.
- Reflex also ships as a Claude Code plugin (`/plugin marketplace add ursuciprian/reflex`, `/plugin install reflex@reflex`). Prefer `setup-dependencies.sh --apply`: in plugin mode an injection **block** only adds a warning and does not remove the text from the tool result. Use one method, not both.

## Operation

```bash
# Scan local skill directory; default rejects CAUTION and DO_NOT_INSTALL
bash ~/.claude/skills/agent-shield/scripts/guard.sh scan ./untrusted-skill

# Scan and install an external skill to both agents (no overwrite)
bash ~/.claude/skills/agent-shield/scripts/guard.sh install ./untrusted-skill --agent both

# Scan a local file for prompt-injection instructions
reflex scan ./untrusted-text.txt

# Manually inspect an uncertain CAUTION verdict, then *explicitly* accept it
bash ~/.claude/skills/agent-shield/scripts/guard.sh install ./reviewed-skill --agent claude --allow-caution
```

### Trusted sources

Most vendor-shipped skills trip SkillSpector's patterns: Office XML schemas with a byte-order mark look like "hidden instructions", `os.environ.copy()` looks like credential harvesting, and paths a skill creates at runtime count as "incomplete analysis". To keep these usable, `guard.sh` trusts three sources, **by where the skill is installed, never by what its files claim**:

| Source | Recognised when |
|---|---|
| Anthropic | The skill is in `~/.claude/skills/synced/<bucket>/` (claude.ai account sync) and that folder's `manifest.json` lists it with `source` `anthropic` or `anthropic-example`. |
| OpenAI | The skill is in `${CODEX_HOME:-~/.codex}/skills/.system/` next to Codex's `.codex-system-skills.marker`. |
| Agent Shield | The folder is named `agent-shield` and its `SKILL.md` and `scripts/` match the running copy byte for byte. |

For a trusted source, the risk score and incomplete analysis do not block. These still block:

- any finding with severity `CRITICAL`
- YARA malware (`YR1`), webshell (`YR2`), or cryptominer (`YR3`) matches
- dependencies with a known `HIGH` or `CRITICAL` vulnerability (`SC4`)
- scanner errors, failed runs, or malformed reports

The output names the trusted source, and all findings are still listed. Use `--strict` to ignore the trusted list, for example for an audit. To trust another source for everyone, edit `trusted_source()` in `scripts/guard.sh`.

**Local trusted directories.** To trust a source on your machine only, add `LABEL=DIRECTORY` lines to `~/.config/agent-shield/trusted-dirs` (or under `$XDG_CONFIG_HOME`). Skills directly inside `DIRECTORY` (after resolving symlinks) get the trusted policy. The file is ignored unless you own it and only you can write it (`chmod 600`). Prefer directories only root can write, such as skills shipped by a signed distro package. Find the owning package with `pacman -Qo`, `dpkg -S`, or `rpm -qf`, then add for example:

```
MyDistro=/usr/share/my-distro/agents/skills
```

`--allow-caution` never overrides a `DO_NOT_INSTALL` verdict, a scanner error, or incomplete analysis. It is an **explicit** exception for a human-reviewed `CAUTION` result. Do not let an autonomous agent choose this option on its own.

The wrapper only installs **local directories**, not remote URLs or archives. Download/inspect and unpack external skill sources outside trusted locations first, then scan their directory. Never run their setup scripts before scanning. Candidates containing symlinks or special files (FIFOs, devices, sockets) are rejected.

## Token cost

Agent Shield itself makes **no LLM calls**: SkillSpector runs with `--no-llm`, and Reflex is set up with the rules-only `local` engine and its LLM judge turned off. The only cost is the text that lands in your agent's context. Rough numbers (≈4 characters per token):

| When | What enters context | Approx. tokens |
|---|---|---|
| Every session, skill unused | Name + description in the skill listing | ~100 |
| Skill invoked | Full `SKILL.md` body | ~1,100 |
| `guard.sh scan` / `install` | Command + verdict line + up to 10 findings | 100–400 per call |
| `guard.sh status` | `reflex doctor` + `reflex status` output | ~300–1,500 (depends on Reflex version) |
| Agent reads `README.md` (only on install/limitation questions) | This file | ~4,600 |
| Reflex hooks firing (enforce mode) | Only block/warning messages; silent when allowed | 0 normally, ~50–300 per block |

Typical totals, including the agent's own reasoning and tool-call overhead:

- **Idle** (installed, not used): ~100 tokens per session.
- **Health check** ("is my agent protected?"): ~2–3.5k tokens.
- **Scan + install one skill**: ~2–4k tokens. Add ~1k per extra skill scanned in the same session.

Once loaded, the skill body stays in context for the rest of the session and is re-sent each turn, usually as cheap cached input. After auto-compaction, Claude Code re-attaches it (up to 5k tokens per skill). Multiply by your model's per-token price for a dollar figure.

Other Reflex setups do add separate LLM cost: the `jev` engine sends uncovered commands to a hosted model, and the System 2 judge (on by default in Reflex's own `setup` when a `claude`/`codex` CLI is found, with a default budget of 300 calls or $5 a day) calls `claude -p`/`codex exec` or the Anthropic API. `setup-dependencies.sh` disables both. If you also run SkillSpector without `--no-llm` outside this wrapper, that uses an LLM as well.

## Tests

From the repository root:

```bash
python3 -m unittest discover -s tests -v
bash -n install.sh scripts/*.sh
```

Tests use fake scanner responses and temporary home directories; they do not install security products. They run on macOS and Linux.

## Notes

- For mandatory organisation-wide checks, enforce a separate approved installer, permission policy, CI, or endpoint controls; a skill cannot guarantee its own use.
- `install.sh --replace` makes timestamped backups; no privileged install or `sudo` is required.
- This distribution does not bundle Reflex or SkillSpector.

## Upstream review notes

Reflex `0.18.2` was reviewed more closely than SkillSpector, since it is a single-maintainer project that sits in every tool call (October 2026):

- The npm tarball matches git tag `v0.18.2` file for file. One extra file, a CI-built `routing/__pycache__/*.pyc`, has bytecode identical to its source and is not loaded (its recorded timestamp does not match).
- No npm dependencies, no install scripts, no self-update, no `eval`. Setup writes only `~/.local/share/reflex`, `~/.local/bin/reflex`, `~/.config/reflex`, `~/.local/state/reflex`, and the hooks in `~/.claude/settings.json` and `~/.codex/hooks.json` (keeping your other settings). It adds `ask` rules so agents must ask before editing Reflex's own files. It does not touch shell profiles.
- Network use is limited to: the optional LLM providers (`jev`, judge), a Prometheus push only with `reflex report --push`, decision webhooks only if you configure `notify` yourself, and a localhost health check for the optional Laya engine. With this setup none of them run.
- A repository's `.reflex/policy.json` can only add checks; anything that loosens them (its fast lane) or sends data (its webhook) needs `reflex trust` from your terminal, bound to the file's hash.
- The pre-run gate fails closed on its own errors (asks you), but a hook **timeout** lets the action run (agent behaviour, documented upstream).

## Source references

- Reflex: https://github.com/ursuciprian/reflex
- SkillSpector: https://github.com/NVIDIA/skillspector
- Claude Code skills: https://code.claude.com/docs/en/skills
- Codex skills: https://learn.chatgpt.com/docs/build-skills
