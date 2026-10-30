"""Offline contract tests. Mock SkillSpector; no third-party installers run."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts" / "guard.sh"
INSTALL = ROOT / "install.sh"
MOCK = '''#!/usr/bin/env python3
import json, os, sys
out = sys.argv[sys.argv.index('--output') + 1]
recommendation = os.environ.get('MOCK_VERDICT', 'SAFE')
if os.environ.get('MOCK_BAD_JSON') == '1':
    open(out, 'w').write('not json')
else:
    report = {
        'risk_assessment': {'score': {'SAFE':0,'CAUTION':30,'DO_NOT_INSTALL':65}[recommendation],
                            'recommendation': recommendation},
        'skill': {'name': 'demo'}, 'issues': []}
    with open(out, 'w') as f: json.dump(report, f)
sys.exit(int(os.environ.get('MOCK_EXIT', '0')))
'''

class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / 'home'
        self.home.mkdir()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        scanner = self.bin / 'skillspector'
        scanner.write_text(MOCK)
        scanner.chmod(0o755)
        self.skill = self.base / 'demo-skill'
        self.skill.mkdir()
        (self.skill / 'SKILL.md').write_text('---\nname: demo-skill\ndescription: demo\n---\n# Hi\n')
        self.env = os.environ.copy()
        self.env.update(HOME=str(self.home), PATH=str(self.bin)+os.pathsep+self.env.get('PATH',''),
                        TMPDIR=str(self.base))

    def run_guard(self, *args, env=None):
        return subprocess.run(['bash', str(GUARD), *map(str,args)], text=True,
                              capture_output=True, env=env or self.env, timeout=20)

    def test_safe_scan(self):
        result = self.run_guard('scan', self.skill)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PASS:', result.stdout)

    def test_caution_requires_human_exception(self):
        env = dict(self.env, MOCK_VERDICT='CAUTION')
        self.assertNotEqual(self.run_guard('scan', self.skill, env=env).returncode, 0)
        self.assertEqual(self.run_guard('scan', self.skill, '--allow-caution', env=env).returncode, 0)

    def test_high_risk_blocked_even_with_exception(self):
        env = dict(self.env, MOCK_VERDICT='DO_NOT_INSTALL', MOCK_EXIT='1')
        self.assertNotEqual(self.run_guard('scan', self.skill, '--allow-caution', env=env).returncode, 0)

    def test_scanner_error_fails_closed(self):
        env = dict(self.env, MOCK_EXIT='2')
        self.assertNotEqual(self.run_guard('scan', self.skill, env=env).returncode, 0)

    def test_bad_report_fails_closed(self):
        env = dict(self.env, MOCK_BAD_JSON='1')
        self.assertNotEqual(self.run_guard('scan', self.skill, env=env).returncode, 0)

    def test_install_both(self):
        result = self.run_guard('install', self.skill, '--agent', 'both')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home/'.claude/skills/demo-skill/SKILL.md').is_file())
        self.assertTrue((self.home/'.agents/skills/demo-skill/SKILL.md').is_file())
        self.assertNotEqual(self.run_guard('install', self.skill, '--agent', 'both').returncode, 0)

    def test_symlink_candidate_rejected(self):
        (self.skill / 'outside').symlink_to(self.home)
        result = self.run_guard('install', self.skill)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('symbolic links', result.stderr)

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'needs POSIX FIFOs')
    def test_special_file_candidate_rejected(self):
        os.mkfifo(self.skill / 'pipe')
        result = self.run_guard('install', self.skill)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('special files', result.stderr)
        self.assertFalse((self.home/'.claude/skills/demo-skill').exists())

    def test_name_mismatch_rejected(self):
        (self.skill / 'SKILL.md').write_text('---\r\nname: "agent-shield"\r\ndescription: x\r\n---\r\n')
        result = self.run_guard('install', self.skill)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not match', result.stderr)
        self.assertFalse((self.home/'.claude/skills/demo-skill').exists())

    def test_symlinked_tmpdir_works(self):
        real = self.base / 'realtmp'
        real.mkdir()
        link = self.base / 'linktmp'
        link.symlink_to(real)
        result = self.run_guard('scan', self.skill, env=dict(self.env, TMPDIR=str(link)))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_setup_default_is_dry_plan(self):
        result = subprocess.run(['bash', str(ROOT/'scripts'/'setup-dependencies.sh')],
                                capture_output=True, text=True, env=self.env, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Nothing installed', result.stdout)
        self.assertIn('skillspector.git@v', result.stdout)
        self.assertIn('--engine local --allow off', result.stdout)

    def test_install_meta_skill(self):
        result = subprocess.run(['bash', str(INSTALL)], capture_output=True, text=True,
                                env=self.env, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home/'.claude/skills/agent-shield/SKILL.md').is_file())
        self.assertTrue((self.home/'.agents/skills/agent-shield/SKILL.md').is_file())
        self.assertTrue((self.home/'.claude/skills/agent-shield/scripts/guard.sh').is_file())
        self.assertFalse((self.home/'.claude/skills/agent-shield/tests').exists())
        self.assertFalse((self.home/'.claude/skills/agent-shield/.git').exists())
        self.assertNotEqual(subprocess.run(['bash', str(INSTALL)], capture_output=True,
                                       env=self.env, timeout=20).returncode, 0)

if __name__ == '__main__':
    unittest.main()
