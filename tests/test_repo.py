"""Static checks: pins, docs, and workflows stay consistent. No network, no installs."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
WORKFLOWS = sorted((ROOT / '.github' / 'workflows').glob('*.yml'))


def pins():
    values = {}
    for line in (SCRIPTS / 'pins.sh').read_text().splitlines():
        match = re.fullmatch(r'([A-Z_]+)=(\S+)', line.strip())
        if match:
            values[match.group(1)] = match.group(2)
    return values


class PinTests(unittest.TestCase):
    def test_pin_formats(self):
        p = pins()
        self.assertRegex(p['SKILLSPECTOR_VERSION'], r'^\d+\.\d+\.\d+$')
        self.assertRegex(p['SKILLSPECTOR_COMMIT'], r'^[0-9a-f]{40}$')
        self.assertRegex(p['SKILLSPECTOR_REPO'], r'^https://github\.com/[\w.-]+/[\w.-]+\.git$')
        self.assertRegex(p['REFLEX_VERSION'], r'^\d+\.\d+\.\d+$')
        self.assertRegex(p['REFLEX_INTEGRITY'], r'^sha512-[A-Za-z0-9+/]{86}==$')

    def test_pin_comments_match_versions(self):
        text = (SCRIPTS / 'pins.sh').read_text()
        p = pins()
        self.assertIn(f'tag v{p["SKILLSPECTOR_VERSION"]}', text)
        self.assertIn(f'(tag v{p["REFLEX_VERSION"]})', text)

    def test_docs_match_pins(self):
        p = pins()
        readme = (ROOT / 'README.md').read_text()
        self.assertIn(f'SkillSpector `v{p["SKILLSPECTOR_VERSION"]}`', readme)
        self.assertIn(f'Reflex `{p["REFLEX_VERSION"]}`', readme)
        self.assertIn(f'`{p["SKILLSPECTOR_COMMIT"][:8]}', readme)

    def test_build_requirements_are_exact_and_hashed(self):
        text = (SCRIPTS / 'skillspector-build.txt').read_text()
        entries = re.split(r'\n(?=[A-Za-z])', '\n'.join(
            line for line in text.splitlines() if line and not line.startswith('#')))
        self.assertTrue(entries)
        names = [e.split('==')[0] for e in entries]
        self.assertIn('hatchling', names)
        for entry in entries:
            with self.subTest(entry=entry.split()[0]):
                self.assertRegex(entry, r'^[A-Za-z0-9._-]+==[0-9][\w.]*\s*\\\s*\n\s*--hash=sha256:[0-9a-f]{64}$')

    def test_setup_never_uses_latest_or_npx(self):
        text = (SCRIPTS / 'setup-dependencies.sh').read_text()
        code = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
        self.assertNotRegex(code, r'\bnpx\b')
        self.assertNotRegex(code, r'@latest\b')
        self.assertIn('--locked', code)
        self.assertIn('--require-hashes', code)
        self.assertIn('--no-index', code)


class ScriptTests(unittest.TestCase):
    def test_shell_scripts_are_strict(self):
        for script in (ROOT / 'install.sh', SCRIPTS / 'guard.sh', SCRIPTS / 'setup-dependencies.sh'):
            with self.subTest(script=script.name):
                lines = script.read_text().splitlines()
                self.assertEqual(lines[0], '#!/usr/bin/env bash')
                self.assertIn('set -euo pipefail', lines[:5])

    def test_skill_front_matter(self):
        text = (ROOT / 'SKILL.md').read_text()
        front = text.split('---', 2)[1]
        self.assertRegex(front, r'(?m)^name: agent-shield$')
        self.assertRegex(front, r'(?m)^description:')
        self.assertIn('${CLAUDE_SKILL_DIR}', text)


class WorkflowTests(unittest.TestCase):
    def test_workflows_exist(self):
        self.assertTrue(WORKFLOWS)

    def test_actions_pinned_to_commit(self):
        for wf in WORKFLOWS:
            for line in wf.read_text().splitlines():
                match = re.search(r'\buses:\s*(\S+)', line)
                if not match or match.group(1).startswith('./'):
                    continue
                with self.subTest(workflow=wf.name, uses=match.group(1)):
                    self.assertRegex(match.group(1), r'^[\w.-]+/[\w./-]+@[0-9a-f]{40}$')
                    self.assertRegex(line, r'#\s*v\d', 'add the version as a comment')

    def test_least_privilege_and_no_persisted_credentials(self):
        for wf in WORKFLOWS:
            text = wf.read_text()
            with self.subTest(workflow=wf.name):
                self.assertRegex(text, r'(?m)^permissions:\s*\{\}\s*$')
                self.assertNotIn('pull_request_target', text)
                self.assertNotRegex(text, r'(?m)^\s*permissions:\s*write-all')
                checkouts = len(re.findall(r'uses:\s*actions/checkout@', text))
                self.assertEqual(len(re.findall(r'persist-credentials:\s*false', text)), checkouts)


if __name__ == '__main__':
    unittest.main()
