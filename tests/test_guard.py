"""Offline contract tests. Mock SkillSpector; no third-party installers run."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts" / "guard.sh"
INSTALL = ROOT / "install.sh"
# CI also runs the suite with macOS /bin/bash (3.2) to check old-bash compatibility.
BASH = os.environ.get("AGENT_SHIELD_TEST_BASH", "bash")
MOCK = '''#!/usr/bin/env python3
import json, os, sys
out = sys.argv[sys.argv.index('--output') + 1]
if os.environ.get('MOCK_REFUSE_SYMLINK') == '1' and os.path.islink(sys.argv[2]):
    sys.exit(2)
recommendation = os.environ.get('MOCK_VERDICT', 'SAFE')
if os.environ.get('MOCK_BAD_JSON') == '1':
    open(out, 'w').write('not json')
else:
    report = {
        'risk_assessment': {'score': {'SAFE':0,'CAUTION':30,'DO_NOT_INSTALL':65}[recommendation],
                            'recommendation': recommendation},
        'skill': {'name': 'demo'}, 'issues': json.loads(os.environ.get('MOCK_ISSUES', '[]'))}
    with open(out, 'w') as f: json.dump(report, f)
sys.exit(int(os.environ.get('MOCK_EXIT', '0')))
'''

class Base(unittest.TestCase):
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
                        TMPDIR=str(self.base), XDG_CONFIG_HOME=str(self.home/'.config'))
        self.env.pop('CODEX_HOME', None)

    def run_guard(self, *args, env=None):
        return subprocess.run([BASH, str(GUARD), *map(str,args)], text=True,
                              capture_output=True, env=env or self.env, timeout=20)


class GuardTests(Base):
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
        result = subprocess.run([BASH, str(ROOT/'scripts'/'setup-dependencies.sh')],
                                capture_output=True, text=True, env=self.env, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Nothing installed', result.stdout)
        pins = dict(line.split('=', 1) for line in (ROOT/'scripts'/'pins.sh').read_text().splitlines()
                    if '=' in line and not line.startswith('#'))
        self.assertIn(pins['SKILLSPECTOR_COMMIT'], result.stdout)
        self.assertIn(pins['REFLEX_INTEGRITY'], result.stdout)
        self.assertIn('--locked', result.stdout)
        self.assertIn('--engine local --allow off', result.stdout)
        self.assertNotIn('npx', result.stdout)
        self.assertNotIn('latest', result.stdout)

    def test_install_meta_skill(self):
        result = subprocess.run([BASH, str(INSTALL)], capture_output=True, text=True,
                                env=self.env, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home/'.claude/skills/agent-shield/SKILL.md').is_file())
        self.assertTrue((self.home/'.agents/skills/agent-shield/SKILL.md').is_file())
        self.assertTrue((self.home/'.claude/skills/agent-shield/scripts/guard.sh').is_file())
        self.assertFalse((self.home/'.claude/skills/agent-shield/tests').exists())
        self.assertFalse((self.home/'.claude/skills/agent-shield/.git').exists())
        replaced = subprocess.run([BASH, str(INSTALL), '--replace'], capture_output=True, text=True,
                                  env=self.env, timeout=20)
        self.assertEqual(replaced.returncode, 0, replaced.stderr)
        self.assertEqual(sorted(p.name for p in (self.home/'.claude/skills').iterdir()), ['agent-shield'])
        self.assertEqual(len(list((self.home/'.agent-shield-backups').iterdir())), 2)
        self.assertNotEqual(subprocess.run([BASH, str(INSTALL)], capture_output=True,
                                       env=self.env, timeout=20).returncode, 0)

class TrustedSourceTests(Base):
    """Anthropic/OpenAI/self are trusted by location; hard findings still block."""

    def make_skill(self, parent, name='vendor-skill'):
        skill = parent / name
        skill.mkdir(parents=True)
        (skill / 'SKILL.md').write_text(f'---\nname: {name}\ndescription: x\n---\n')
        return skill

    def anthropic_skill(self, source='anthropic'):
        bucket = self.home / '.claude/skills/synced/bucket-1'
        skill = self.make_skill(bucket)
        (bucket / 'manifest.json').write_text(json.dumps(
            {'skills': [{'skillId': 'vendor-skill', 'source': source}]}))
        return skill

    def codex_skill(self, marker=True):
        system = self.home / '.codex/skills/.system'
        skill = self.make_skill(system)
        if marker:
            (system / '.codex-system-skills.marker').write_text('abc')
        return skill

    def risky(self, issues='[]'):
        return dict(self.env, MOCK_VERDICT='DO_NOT_INSTALL', MOCK_EXIT='1', MOCK_ISSUES=issues)

    def test_anthropic_high_score_passes(self):
        result = self.run_guard('scan', self.anthropic_skill(), env=self.risky())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Trusted source: Anthropic', result.stdout)

    def test_openai_high_score_passes(self):
        result = self.run_guard('scan', self.codex_skill(), env=self.risky())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Trusted source: OpenAI', result.stdout)

    def test_self_passes(self):
        result = self.run_guard('scan', ROOT, env=self.risky())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Trusted source: Agent Shield', result.stdout)

    def test_untrusted_manifest_source_blocks(self):
        self.assertNotEqual(self.run_guard('scan', self.anthropic_skill('user'), env=self.risky()).returncode, 0)

    def test_codex_without_marker_blocks(self):
        self.assertNotEqual(self.run_guard('scan', self.codex_skill(marker=False), env=self.risky()).returncode, 0)

    def test_modified_self_copy_blocks(self):
        copy = self.make_skill(self.base / 'elsewhere', 'agent-shield')
        self.assertNotEqual(self.run_guard('scan', copy, env=self.risky()).returncode, 0)

    def test_strict_ignores_trust(self):
        self.assertNotEqual(self.run_guard('scan', self.anthropic_skill(), '--strict', env=self.risky()).returncode, 0)

    def test_trusted_hard_findings_block(self):
        skill = self.anthropic_skill()
        for issue in ({'id': 'YR1', 'severity': 'CRITICAL'}, {'id': 'YR3', 'severity': 'HIGH'},
                      {'id': 'SC4', 'severity': 'HIGH'}, {'id': 'P1', 'severity': 'CRITICAL'}):
            result = self.run_guard('scan', skill, env=self.risky(json.dumps([issue])))
            self.assertNotEqual(result.returncode, 0, issue)
            self.assertIn('HARD:', result.stderr)

    def test_trusted_ordinary_high_findings_pass(self):
        issues = json.dumps([{'id': 'E2', 'severity': 'HIGH'}, {'id': 'SC4', 'severity': 'MEDIUM'}])
        self.assertEqual(self.run_guard('scan', self.anthropic_skill(), env=self.risky(issues)).returncode, 0)

    def test_trusted_scanner_error_blocks(self):
        env = dict(self.env, MOCK_EXIT='2')
        self.assertNotEqual(self.run_guard('scan', self.anthropic_skill(), env=env).returncode, 0)

    def local_trust(self, directory, mode=0o600):
        conf = self.home / '.config/agent-shield/trusted-dirs'
        conf.parent.mkdir(parents=True, exist_ok=True)
        conf.write_text(f'# local\nDistro={directory}\n')
        conf.chmod(mode)

    def test_local_trusted_dir_passes(self):
        system = self.base / 'usr-share-skills'
        skill = self.make_skill(system)
        link = self.home / '.claude/skills/vendor-skill'
        link.parent.mkdir(parents=True)
        link.symlink_to(skill)
        self.local_trust(system)
        result = self.run_guard('scan', link, env=self.risky())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Trusted source: Distro (local trusted directory', result.stdout)

    def test_local_trust_only_matches_listed_dir(self):
        self.local_trust(self.base / 'other')
        (self.base / 'other').mkdir()
        skill = self.make_skill(self.base / 'usr-share-skills')
        self.assertNotEqual(self.run_guard('scan', skill, env=self.risky()).returncode, 0)

    def test_writable_local_trust_file_ignored(self):
        system = self.base / 'usr-share-skills'
        skill = self.make_skill(system)
        self.local_trust(system, mode=0o666)
        result = self.run_guard('scan', skill, env=self.risky())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ignoring', result.stderr)

    def test_scan_resolves_symlinked_skill(self):
        link = self.base / 'link-skill'
        link.symlink_to(self.skill)
        env = dict(self.env, MOCK_REFUSE_SYMLINK='1')
        result = self.run_guard('scan', link, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Scanning link target', result.stdout)

    def test_trusted_install_to_codex(self):
        result = self.run_guard('install', self.anthropic_skill(), '--agent', 'codex', env=self.risky())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home/'.agents/skills/vendor-skill/SKILL.md').is_file())


if __name__ == '__main__':
    unittest.main()
