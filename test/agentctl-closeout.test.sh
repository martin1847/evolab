#!/usr/bin/env bash
# Real squash fixtures; only one declared tree may be archived and removed, never by stop.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
from __future__ import annotations

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
FIXTURES = ROOT / '.git/worktree-close-tests-1016'
FIXTURES.mkdir(parents=True, exist_ok=True)
AGENTCTL = ROOT / 'skills/cto-orchestration/references/agentctl/agentctl'
UNDER_TEST = Path(os.environ.get('AGENTCTL_CLOSEOUT_UNDER_TEST', str(AGENTCTL)))
BASE = '648b9efd476bd6717fb8254cd851c28112b0bf3d'
ENV = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='fixture', GIT_AUTHOR_EMAIL='fixture@invalid',
           GIT_COMMITTER_NAME='fixture', GIT_COMMITTER_EMAIL='fixture@invalid')
for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
    ENV.pop(key, None)


def invoke(argv: list[str], cwd: Path, env: dict[str, str] = ENV) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True)
    print(f'$ (cwd={cwd}) {shlex.join(argv)}\nrc={result.returncode}', flush=True)
    for label, data in [('stdout', result.stdout), ('stderr', result.stderr)]:
        if data:
            print(label + ':\n' + data.decode(errors='replace'), flush=True)
    return result


def git(repo: Path, *args: str) -> str:
    result = invoke(['git', '-C', str(repo), *args], repo)
    if result.returncode:
        raise AssertionError(f'fixture git failed: {args}')
    return result.stdout.decode().strip()


class Closeout(unittest.TestCase):
    def setUp(self) -> None:
        self.home = Path(tempfile.mkdtemp(prefix='zz-closeout-', dir=FIXTURES)).resolve()
        self.repo = self.home / 'zz-main'
        self.repo.mkdir()
        git(self.repo, 'init', '-b', 'main')
        git(self.repo, 'config', 'core.hooksPath', '/dev/null')
        (self.repo / '.gitignore').write_text('reports/\n')
        (self.repo / 'tracked.txt').write_text('base\n')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-m', 'fixture base')
        self.tree = self.home / 'zz-linked'
        git(self.repo, 'worktree', 'add', '-b', 'zz-completed', str(self.tree))
        (self.tree / 'tracked.txt').write_text('integrated\n')
        git(self.tree, 'commit', '-am', 'fixture task')
        self.head = git(self.tree, 'rev-parse', 'HEAD')
        git(self.repo, 'merge', '--squash', 'zz-completed')
        git(self.repo, 'commit', '-m', 'fixture squash')
        self.integrated = git(self.repo, 'rev-parse', 'HEAD')
        self.assertEqual(1, invoke(['git', '-C', str(self.repo), 'merge-base', '--is-ancestor',
                                    self.head, 'main'], self.repo).returncode)
        self.acceptance = self.home / 'zz-acceptance.md'
        self.acceptance.write_text(f'Operator accepted source {self.head}\n'
                                   f'Integrated as {self.integrated} on main\n')
        self.kept = {'REVIEW.md': b'accepted report\n\x00raw bytes\n',
                     'reports/IMPL.md': b'ignored implementation evidence\n'}
        for relative, data in self.kept.items():
            path = self.tree / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.archive = self.home / 'zz-archive'

    def close(self, entry: Path = UNDER_TEST) -> subprocess.CompletedProcess[bytes]:
        argv = ['bash', str(entry), 'closeout', str(self.tree), '--archive', str(self.archive),
                '--source-head', self.head, '--acceptance', str(self.acceptance),
                '--integrated-as', self.integrated, '--base-ref', 'main']
        for relative in self.kept:
            argv.extend(['--keep', relative])
        return invoke(argv, self.repo)

    def assert_sources(self) -> None:
        for relative, data in self.kept.items():
            self.assertEqual(data, (self.tree / relative).read_bytes())
        self.assertIn(str(self.tree), git(self.repo, 'worktree', 'list', '--porcelain'))
        self.assertEqual(self.head, git(self.repo, 'rev-parse', 'zz-completed'))

    def test_squash_closeout_and_stop_retention(self) -> None:
        original = invoke(['git', '-C', str(ROOT), 'show',
                           f'{BASE}:skills/cto-orchestration/references/agentctl/agentctl'], ROOT)
        self.assertEqual(0, original.returncode)
        control = self.home / 'zz-pinned-agentctl'
        control.write_bytes(original.stdout)
        self.assertNotEqual(0, self.close(control).returncode)
        self.assert_sources()
        self.assertFalse(self.archive.exists())

        # No real agents, tmux sessions or process inventory: stop sees only fake post-mortem state.
        bin_dir = self.home / 'zz-bin'
        bin_dir.mkdir()
        for name in ('tmux', 'ps'):
            fake = bin_dir / name
            fake.write_text('#!/usr/bin/env bash\nexit 1\n')
            fake.chmod(0o755)
        run = self.home / 'zz-run'
        run.mkdir()
        events = run / 'zz-finished.duplex.events.jsonl'
        events.write_text('{}\n')
        stop_env = dict(ENV, PATH=str(bin_dir) + os.pathsep + ENV['PATH'],
                        AGENT_WATCH_DIR=str(run))
        stop_env.pop('AGENTCTL_SESSION', None)
        stopped = invoke(['bash', str(UNDER_TEST), 'stop', 'zz-finished'], self.repo, stop_env)
        self.assertEqual(0, stopped.returncode)
        self.assertEqual('{}\n', events.read_text())
        self.assert_sources()

        self.assertEqual(0, self.close().returncode, 'head assertion: public closeout must succeed')
        self.assertFalse(self.tree.exists())
        self.assertNotIn(str(self.tree), git(self.repo, 'worktree', 'list', '--porcelain'))
        self.assertEqual(self.head, git(self.repo, 'rev-parse', 'zz-completed'))
        for relative, data in self.kept.items():
            self.assertEqual(data, (self.archive / 'files' / relative).read_bytes())
        self.assertEqual(self.acceptance.read_bytes(),
                         (self.archive / 'acceptance' / self.acceptance.name).read_bytes())
        self.assertTrue((self.repo / 'tracked.txt').is_file())

    def test_undeclared_ignored_evidence_retains_tree(self) -> None:
        unknown = self.tree / 'reports/EXTRA.md'
        unknown.write_bytes(b'not declared, must survive\n')
        result = self.close()
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b'undeclared', result.stderr)
        self.assert_sources()
        self.assertEqual(b'not declared, must survive\n', unknown.read_bytes())
        self.assertFalse(self.archive.exists())


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
