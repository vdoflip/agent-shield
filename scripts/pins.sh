# Pinned upstream releases. setup-dependencies.sh installs exactly these and
# nothing else; guard.sh status compares installed versions against them.
# Change only after reviewing the new release, and update every value together.
# shellcheck shell=bash disable=SC2034

# NVIDIA SkillSpector: git commit of tag v2.13.2; dependencies come from that
# commit's uv.lock (158 packages, sha256-verified by uv).
SKILLSPECTOR_VERSION=2.13.2
SKILLSPECTOR_COMMIT=abd82935b67f765a9541013c0866c6349251dcdf
SKILLSPECTOR_REPO=https://github.com/NVIDIA/skillspector.git

# Reflex: npm tarball checked against this sha512. It has no dependencies and
# no install scripts. Built from git commit b9ccab191ec7def35aed2ed5816635340e2a8650 (tag v0.18.2).
REFLEX_VERSION=0.18.2
REFLEX_INTEGRITY=sha512-mnuTeNv8WG3a3qVpZ2rtgHtu3c95/0RkVy+aryQttOEUcg9QoyAzJxfl/QuRKMRlU8o9YUzo6hJV8IiRM3xQyw==
