#!/usr/bin/env python3
"""doc-lifecycle — 文档年龄清单（只读扫描；没有 --apply，没有一条写路径）。

两个面，同一个判据「有没有人碰」：
  expire  `--docs` 一层里的回执类 `*.md`（= 非 living）整份 TTL 天无提交触碰 ⇒ 进清单
  cool    living 登记簿（`--living`）里无 `PREMISE:` 断言且 TTL 天无提交触碰的段落 ⇒ 进清单

判据只有两条，都不是「重要性」：能不能证伪（带 PREMISE 行的段落归 claims runner，永不进清单），
有没有人碰。续命写法 `<!-- keep-until: YYYY-MM-DD -->`——写在文件头（第一个 `##` 之前）保全整份
文件，写在段内只保全该段；日期已过不算续命（唯一的续命动作是改文件，不是改日期）。

年龄一律问 git，不问 mtime：mtime 是签出时间，一次 clone 就把整棵树读成「今天刚写的」，而那恰好
是最容易被误信的答案。文件级 `git log -1 --format=%ct`，段落级 `git log -L<a>,<b>`（git 自己跟踪
行的漂移）。living 允许是指向另一个仓的 symlink，所以两者都问 realpath 之后那个文件自己的那棵树，
不是扫描面碰巧在的那棵。

搬与不搬由人拍：本脚本只把「谁多久没人碰」摆到台面上，一个字节都不改。它要买的是——收口归档靠
人记，于是没人碰的回执与陈旧段落永远活着。

不处理的形态一律整条跳过并列一行 `skip: <谁> (<原因>)`，exit 仍为 0：
  no-git   目标文件不在 git 仓 / 历史读不出来 —— 年龄判不了，拒绝退回 mtime 报一个空清单
  dirty    该文件有未提交改动 —— 工作树行号喂给 `git log -L` 指的是 HEAD 里的另一段内容
  missing  living 名单里的文件不在（缺的面不静默丢）
量具面本身缺失（`--docs` 不是目录）⇒ exit 2：一个扫不到的面不是一个干净的面。

Usage: doc-lifecycle.py --docs <dir> [--living ACTIVE_CONTEXT.md,...] [--ttl 45]
"""

import argparse
import datetime as dt
import re
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_TTL = 45
# living 默认名单（相对 `--docs`）：登记簿三件。别的仓靠 `--living` 换名单，不改这里。
DEFAULT_LIVING = ("ACTIVE_CONTEXT.md", "DECISION_QUEUE.md", "LESSONS.md")
KEEP_UNTIL = re.compile(r"<!--\s*keep-until:\s*(\d{4})-(\d{2})-(\d{2})\s*-->")
HEADING = re.compile(r"^(?:##|###)\s+(.*\S)\s*$")
PREMISE = re.compile(r"PREMISE\s*[:：]")


def git(cwd, *args):
    """stdout；git 返回非 0 或跑不起来 ⇒ None（调用方一律折成 skip，从不猜年龄）。"""
    try:
        r = subprocess.run(("git", "-C", str(cwd)) + args, capture_output=True, text=True)
    except OSError:
        return None
    return r.stdout if r.returncode == 0 else None


def days(stamp, now):
    return (now - stamp) / 86400.0


def sections(body):
    """[(标题, 起始行, 结束行)]：以每个 `##`/`###` 为界切成不重叠的块；文件头不算段。"""
    lines = body.split("\n")
    heads = [(i + 1, m.group(1)) for i, ln in enumerate(lines)
             for m in [HEADING.match(ln)] if m]
    return [(title, start, heads[i + 1][0] - 1 if i + 1 < len(heads) else len(lines))
            for i, (start, title) in enumerate(heads)]


def head_text(body, secs):
    """文件头 = 第一个 `##`/`###` 之前的部分（keep-until 写这里 = 整文件续命）。"""
    return body if not secs else "\n".join(body.split("\n")[:secs[0][1] - 1])


def kept_alive(text, today):
    """文本里有未过期的 keep-until ⇒ True。"""
    m = KEEP_UNTIL.search(text)
    if not m:
        return False
    try:
        return dt.date(*(int(g) for g in m.groups())) >= today
    except ValueError:      # 2026-13-45 一类写坏的日期不是续命
        return False


class Scan:
    """一次只读扫描：living（解 symlink）+ ephemeral 两个面，按 git 年龄出清单。"""

    def __init__(self, docs, living, ttl, now):
        self.docs = docs
        self.ttl = ttl
        self.now = now
        self.today = dt.date.fromtimestamp(now)
        self.skips = []
        self._repos = {}
        self.living = []
        for name in living:
            path = self.docs / name
            if path.is_file():
                self.living.append((name, path.resolve()))
            else:
                self.skips.append(f"{name} (missing)")
        reals = {real for _name, real in self.living}
        # 只扫一层 `*.md`：`archive/` 与别的子目录按构造就在扫描面之外，不需要再减一次
        self.ephemeral = [p for p in sorted(self.docs.glob("*.md"))
                          if p.is_file() and p.resolve() not in reals]

    def repo(self, real):
        """目标文件自己的那棵树的仓根；不在任何仓 ⇒ None。按父目录缓存，一个目录只问一次。"""
        parent = real.parent
        if parent not in self._repos:
            out = git(parent, "rev-parse", "--show-toplevel")
            self._repos[parent] = Path(out.strip()).resolve() if out and out.strip() else None
        return self._repos[parent]

    def name(self, real):
        """清单里的显示名 = 目标文件在它自己仓里的相对路径（不在仓里就是绝对路径）。"""
        root = self.repo(real)
        return str(real.relative_to(root)) if root else str(real)

    def file_age(self, real):
        """整份文件最后一次被 commit 触碰至今的天数；历史读不出来 ⇒ None。"""
        out = git(real.parent, "log", "-1", "--format=%ct", "--", real.name)
        if out is None or not out.strip():
            return None
        return days(float(out.strip()), self.now)

    def dirty(self, real):
        """该文件有未提交改动 —— 年龄口径（尤其段落行号）不可信的信号。"""
        return bool((git(real.parent, "status", "--porcelain", "--", real.name) or "").strip())

    def section_age(self, real, start, end, fallback):
        """段落最后一次被 commit 触碰至今的天数；`-L` 查不出来（区间越界等）退回文件级。"""
        out = git(real.parent, "log", f"-L{start},{end}:{real.name}",
                  "--format=%ct", "-s", "-1")
        if out and out.strip():
            return days(float(out.strip().split("\n")[0]), self.now)
        return fallback

    def judge(self, name, real):
        """(文件正文, 段落切分, 文件年龄)；判不了的形态记一行 skip 并返回 None。"""
        body = real.read_text(encoding="utf-8", errors="replace")
        secs = sections(body)
        if kept_alive(head_text(body, secs), self.today):
            return None
        if self.dirty(real):
            self.skips.append(f"{name} (dirty)")
            return None
        age = self.file_age(real)
        if age is None:
            self.skips.append(f"{name} (no-git)")
            return None
        return body, secs, age

    def expire(self):
        """[(显示名, 天数)]：TTL 天无人碰的回执。"""
        rows = []
        for path in self.ephemeral:
            real = path.resolve()
            verdict = self.judge(self.name(real), real)
            if verdict is None:
                continue
            _body, _secs, age = verdict
            if age > self.ttl:
                rows.append((self.name(real), age))
        return rows

    def cool(self):
        """[(显示名, 标题, 起, 止, 天数)]：登记簿里无断言且 TTL 天无人碰的段落。"""
        rows = []
        for name, real in self.living:
            verdict = self.judge(name, real)
            if verdict is None:
                continue
            body, secs, file_age = verdict
            lines = body.split("\n")
            disp = self.name(real)
            for title, start, end in secs:
                chunk = "\n".join(lines[start - 1:end])
                if PREMISE.search(chunk) or kept_alive(chunk, self.today):
                    continue
                age = self.section_age(real, start, end, file_age)
                if age > self.ttl:
                    rows.append((disp, title, start, end, age))
        return rows


def main(argv):
    ap = argparse.ArgumentParser(description="文档年龄清单（只读）")
    ap.add_argument("--docs", required=True, help="扫描面目录（一层 *.md + living 登记簿）")
    ap.add_argument("--living", default=",".join(DEFAULT_LIVING),
                    help="逗号分隔的 living 名单，相对 --docs")
    ap.add_argument("--ttl", type=int, default=DEFAULT_TTL, help=f"天数阈值（默认 {DEFAULT_TTL}）")
    args = ap.parse_args(argv)

    docs = Path(args.docs)
    if not docs.is_dir():
        print(f"doc-lifecycle: --docs 不存在或不是目录：{docs}", file=sys.stderr)
        return 2
    living = tuple(n.strip() for n in args.living.split(",") if n.strip())
    scan = Scan(docs.resolve(), living, args.ttl, time.time())
    expired = scan.expire()
    cooled = scan.cool()
    for disp, age in expired:
        print(f"expire: {disp} age={age:.0f}d")
    for disp, title, start, end, age in cooled:
        print(f"cool: {disp}#{title} lines={start}-{end} age={age:.0f}d")
    for note in scan.skips:
        print(f"skip: {note}")
    print(f"doc-lifecycle: {len(expired)} 件到期，{len(cooled)} 段可降温")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
