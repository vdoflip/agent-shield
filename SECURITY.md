# Security policy

Agent Shield is a security tool, so bugs that weaken its guarantees are security issues. Examples:

- `guard.sh` letting a skill pass that should be blocked, or trusting a source it should not
- `setup-dependencies.sh` installing anything other than the versions pinned in `scripts/pins.sh`
- `install.sh` following symlinks, overwriting without `--replace`, or writing outside its target folders
- scanner output being able to inject instructions or fake verdicts into what an agent reads

## Reporting a vulnerability

Please report privately through GitHub: **Security → Report a vulnerability** on this repository
(<https://github.com/vdoflip/agent-shield/security/advisories/new>). Do not open a public issue.

Include what you ran, what happened, and what you expected. You should get a first reply within a week.

Problems in the upstream tools belong upstream:
[NVIDIA SkillSpector](https://github.com/NVIDIA/skillspector/security) and
[Reflex](https://github.com/ursuciprian/reflex/security).

## Supported versions

Only the latest commit on `main` is supported.
