#!/usr/bin/env python3
"""session-economics — 会话经济的两个面，一个文件两个入口（提醒 + 读数，共用同一套 transcript 读法）。

病：成本 = Σ 每次调用时的上下文体量。一个不换的编排会话把 400-550k 的上下文乘进它剩下的每一次
请求，闲置过缓存 TTL 的下一条请求还要按 2× 单价整段重缓存。retrospective §7 的「换会话」是散文，
而该换的那一刻没有任何东西说话。

无 argv（stdin = hook 载荷）⇒ **触点**：UserPromptSubmit 上一行 additionalContext，只在两种时刻说：
  ① 上下文首次越过 300k / 450k / 600k（试行阈值，每档每 session 一次）
  ② 距上一条 assistant >55 分钟且上下文 ≥150k（缓存 1h 过期边界的提前量；同一次闲置一次）
不拦、不改状态、不判对错——**只提醒**：越档与否是判据，换不换会话是人拍。其余每一条 prompt 输出
零字节，任何异常也是零字节 + exit 0（一个提醒永远不该成为会话的故障点）。

`--report <transcript-dir> [--days N]` ⇒ **读数**：复盘时把「这些会话到底多贵」摆到台面上（retro-check
第 12 检的输入），只读、只出清单、不改一个字节。

边界，写出来而不是假装没有（主理人 0918 裁：边界一律最小化）：触点只读 transcript **尾部**有界字节，
所以一条巨大的 tool_result 把最后一条 assistant 顶出窗口 ⇒ 这一条 prompt 不提醒（不是报错）。巨大 /
被截断 / 并发写入的 transcript、多 worktree 共享 session、时钟漂移一律不专门处理：遇到即静默。
读数模式判不出的会话打一行 `[skip]`，不猜。
"""

import datetime as dt
import glob
import json
import os
import re
import statistics
import sys
import time

# ── 触点阈值（**试行**，30 天按第 12 检读数校准；GATE-AUDIT slug `ctx-nudge`，到期 2026-10-23）──
CTX_TIERS = (300_000, 450_000, 600_000)
IDLE_MINUTES = 55.0          # 缓存 TTL 1h，55 分钟是提前量：过了就是整段重缓存（2× 单价）
IDLE_CTX_FLOOR = 150_000     # 以下重写便宜，不值一句话
# 尾读上限：触点只要最后一条 assistant 的 usage 与 timestamp 两个字段。一条 assistant 行通常 <10KiB，
# 中间夹的 tool_result 行才是大头，512KiB 覆盖尾部几十行、够跨过寻常的 tool_result；再大就是在每一条
# prompt 上为一个提醒付整文件的解析钱。够不着 ⇒ 这条不提醒（见抬头「边界」）。
TAIL_BYTES = 512 * 1024
STATE_DIR = "ctx-nudge"      # 在 identity.run_dir() 下；session 粒度，一个 json 一个会话
_SAFE_ID = re.compile(r"[^A-Za-z0-9_.-]")

# ── 读数判据 ──────────────────────────────────────────────────────────────────────────────
REPORT_MIN_MSGS = 5          # 窗口内去重后不足 5 条 assistant 的会话不出行：噪声，不是会话
SPIKE_CACHE_WRITE = 100_000  # 一次 cache_creation 超过它 = 一次整段重缓存
OVER = 300_000               # 汇总口径，与 retrospective §7 的机械阈值同源
# 「只读」的近似判定，advisory：Bash 的写意图靠命令串里的记号猜，猜不全也猜不准（heredoc、`$(…)`、
# 自定义脚本名都能绕过），所以 ro-streak 只是一个「这段像不像在纯调研」的提示，不是判据。
READONLY_TOOLS = frozenset(("Read", "Grep", "Glob", "WebFetch", "WebSearch"))
WRITE_MARKERS = (">", "agentctl start", "agentctl steer", "git commit", "git push",
                 "git merge", "rm ", "mv ", "cp ", "tee", "python3 -")


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0


def _usage(msg):
    """(ctx, cache_creation)，ctx = input + cache_read + cache_creation = 这次调用真正计费的体量。

    `iterations[]` 在则按契约取和（同字段）；没有 usage 字典 ⇒ None（这一行不是一次计费调用）。
    同一条回复的多个 block 各占一行、`message.id` 相同，usage 以**最后一行**为准：前面的行是同一次
    调用的分片，累加会把一次调用读成好几次。"""
    if not isinstance(msg, dict):
        return None
    u = msg.get("usage")
    if not isinstance(u, dict):
        return None
    its = u.get("iterations")
    rows = [r for r in its if isinstance(r, dict)] if isinstance(its, list) else []
    rows = rows or [u]
    tot = {k: sum(_num(r.get(k)) for r in rows)
           for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")}
    return (tot["input_tokens"] + tot["cache_read_input_tokens"]
            + tot["cache_creation_input_tokens"], tot["cache_creation_input_tokens"])


def _ts(row):
    """行时间戳 → epoch 秒；缺失 / 不是 ISO ⇒ None（不猜、不用 mtime 顶替）。"""
    s = row.get("timestamp") if isinstance(row, dict) else None
    if not isinstance(s, str):
        return None
    s = s.strip()
    if s[-1:] in ("Z", "z"):
        s = s[:-1] + "+00:00"
    try:
        d = dt.datetime.fromisoformat(s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.timestamp()


def _k(n):
    return int(round(n / 1000.0))


# ══ 触点模式 ═══════════════════════════════════════════════════════════════════════════════

def _tail_lines(path):
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        off = max(0, size - TAIL_BYTES)
        fh.seek(off)
        blob = fh.read()
    lines = blob.decode("utf-8", "replace").split("\n")
    return lines[1:] if off else lines      # 窗口首行多半被切断，丢掉


def _last_assistant(lines):
    """(ctx, ts) of 最后一条带 usage 的 assistant 行；找不到 ⇒ None。"""
    for ln in reversed(lines):
        if '"assistant"' not in ln:
            continue
        try:
            row = json.loads(ln)
        except Exception:                   # noqa: BLE001 — 半行 / 坏行，继续往前找
            continue
        if not isinstance(row, dict) or row.get("type") != "assistant":
            continue
        u = _usage(row.get("message"))
        if u is None:
            continue
        return u[0], _ts(row)
    return None


def _load_state(path):
    try:
        with open(path, encoding="utf-8") as fh:
            st = json.load(fh)
    except Exception:                       # noqa: BLE001 — 没有 / 坏了 = 还没提醒过
        return {}
    return st if isinstance(st, dict) else {}


def triggers(payload):
    """(tier, ctx, idle, idle_min, ts)，都不触发 ⇒ None。判据全在这里，身份门在调用方。"""
    tp = payload.get("transcript_path")
    if not isinstance(tp, str) or not tp:
        return None
    lines = _tail_lines(tp)
    last = _last_assistant(lines)
    if last is None:
        return None
    ctx, ts = last
    if ctx <= 0:
        return None
    tier = max((t for t in CTX_TIERS if ctx >= t), default=None)
    idle_min = (time.time() - ts) / 60.0 if ts else 0.0
    idle = ts is not None and idle_min > IDLE_MINUTES and ctx >= IDLE_CTX_FLOOR
    if tier is None and not idle:
        return None                          # ← 绝大多数 prompt 在这里结束：没碰 identity，没跑 git
    return (tier, ctx, idle, idle_min, ts)


def hook():
    try:
        payload = json.load(sys.stdin)
    except Exception:                        # noqa: BLE001 — 非 JSON / 空 stdin
        return 0
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "UserPromptSubmit":
        return 0
    sid = payload.get("session_id")
    cwd = payload.get("cwd")
    if not isinstance(sid, str) or not sid or not isinstance(cwd, str) or not cwd:
        return 0
    fired = triggers(payload)
    if fired is None:
        return 0
    tier, ctx, idle, idle_min, ts = fired

    # 有触发才认身份：identity 要花一次 git rev-parse + run dir 列目录，不能压在每条 prompt 上。
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "agentctl"))
    try:
        import identity
    except Exception:                        # noqa: BLE001 — 谓词读不到 ⇒ 不说（提醒宁可漏，不可乱）
        return 0

    spath = os.path.join(identity.run_dir(), STATE_DIR, _SAFE_ID.sub("-", sid)[:120] + ".json")
    st = _load_state(spath)
    seen = [t for t in st.get("tiers", []) if isinstance(t, int)]
    say_tier = tier is not None and tier not in seen
    say_idle = idle and st.get("idle_ts") != ts
    if not say_tier and not say_idle:
        return 0                             # 这一档 / 这一次闲置已经说过了

    state, _why = identity.orchestrated(cwd)
    if state != identity.ORCHESTRATED:
        return 0                             # 非被编排仓（或判不出）：一个字都不说

    parts = []
    if say_tier:
        parts.append(f"💸 上下文 {_k(ctx)}k/请求（阈 {_k(tier)}k）：批次收口即换会话 + /tmp handoff"
                     "（retrospective §7）；等 owner / CI >1h 也换")
    if say_idle:
        parts.append(f"💸 闲置 {int(idle_min)} 分钟（缓存 1h 过期边界），本条很可能整段重缓存"
                     f"（≈2×{_k(ctx)}k）；处在批次边界就先换会话，否则收口再换")
    try:
        os.makedirs(os.path.dirname(spath), exist_ok=True)
        if say_tier:
            seen.append(tier)
        with open(spath, "w", encoding="utf-8") as fh:
            json.dump({"tiers": sorted(set(seen)),
                       "idle_ts": ts if say_idle else st.get("idle_ts")}, fh)
    except Exception:                        # noqa: BLE001 — 合同：任何异常路径零字节；记不住就不说
        return 0                             # （否则持久化一直失败时每条同载荷 prompt 都会重提）
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                             "additionalContext": " · ".join(parts)}},
                     ensure_ascii=False))
    return 0


# ══ 读数模式 ═══════════════════════════════════════════════════════════════════════════════

def _tools(msg):
    """[(name, command)]：这一行里的 tool_use 块。同一条回复的块分散在多行，调用方按 id 累加。"""
    out = []
    content = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(content, list):
        return out
    for b in content:
        if isinstance(b, dict) and b.get("type") == "tool_use":
            inp = b.get("input")
            cmd = inp.get("command") if isinstance(inp, dict) else None
            out.append((b.get("name"), cmd if isinstance(cmd, str) else ""))
    return out


def _is_human(row):
    """人类 prompt 才算一次 human：全是 tool_result 的 user 行是工具回灌，task-notification 是唤醒。"""
    msg = row.get("message")
    if not isinstance(msg, dict):
        return False
    c = msg.get("content")
    if isinstance(c, list):
        blocks = [b for b in c if isinstance(b, dict)]
        if blocks and all(b.get("type") == "tool_result" for b in blocks):
            return False
        text = json.dumps(c, ensure_ascii=False)
    elif isinstance(c, str):
        text = c
    else:
        return False
    return bool(text.strip()) and "task-notification" not in text


def _readonly(tools):
    """True = 这条消息只读；False = 有写意图；None = 没工具（中性，不断也不续 streak）。"""
    if not tools:
        return None
    for name, cmd in tools:
        if name in READONLY_TOOLS:
            continue
        if name == "Bash" and not any(m in cmd for m in WRITE_MARKERS):
            continue
        return False
    return True


def scan(path, cutoff):
    """一个 transcript → 该会话在窗口内的读数 dict；窗口内消息不足 ⇒ None。"""
    msgs, order, humans = {}, [], 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                row = json.loads(raw)
            except Exception:                # noqa: BLE001 — 坏行跳过，坏文件由调用方兜
                continue
            if not isinstance(row, dict):
                continue
            ts = _ts(row)
            if ts is None or ts < cutoff:
                continue
            kind = row.get("type")
            if kind == "assistant":
                msg = row.get("message") if isinstance(row.get("message"), dict) else {}
                key = msg.get("id") or "@%d" % len(order)
                m = msgs.get(key)
                if m is None:
                    m = msgs[key] = {"ctx": 0, "creat": 0, "tools": [], "ts": ts}
                    order.append(key)
                u = _usage(msg)
                if u is not None:
                    m["ctx"], m["creat"] = u  # 最后一行胜（同 id 的前几行是同一次调用的分片）
                m["tools"].extend(_tools(msg))
                m["ts"] = ts
            elif kind == "user" and _is_human(row):
                humans += 1
    seq = [msgs[k] for k in order]
    if len(seq) < REPORT_MIN_MSGS:
        return None
    ctxs = [m["ctx"] for m in seq]
    calls = sum(len(m["tools"]) for m in seq)
    with_tools = sum(1 for m in seq if m["tools"])
    streak = best = 0
    for m in seq:
        ro = _readonly(m["tools"])
        if ro is None:
            continue
        streak = streak + 1 if ro else 0
        best = max(best, streak)
    return {"req": len(seq), "first": seq[0]["ts"], "last": seq[-1]["ts"],
            "med": int(statistics.median(ctxs)), "max": max(ctxs),
            "spikes": sum(1 for m in seq if m["creat"] > SPIKE_CACHE_WRITE),
            "calls": calls / with_tools if with_tools else 0.0,
            "humans": humans, "ro": best}


def report(dirpath, days):
    if not os.path.isdir(dirpath):
        print("[skip] %s 不存在 — 本机没有该仓的 transcript 目录" % dirpath)
        return 0
    files = sorted(glob.glob(os.path.join(dirpath, "*.jsonl")))
    if not files:
        print("[skip] %s 下没有 *.jsonl" % dirpath)
        return 0
    cutoff = time.time() - days * 86400
    meds = []
    over = 0
    for fp in files:
        sid = os.path.basename(fp)[:-len(".jsonl")]
        try:
            r = scan(fp, cutoff)
        except Exception as exc:             # noqa: BLE001 — 坏一个文件不该吞掉其余会话
            print("[skip] %s 读不出 (%s)" % (sid[:8], type(exc).__name__))
            continue
        if r is None:
            continue
        meds.append(r["med"])
        if r["med"] > OVER:
            over += 1
        span = "%s→%s" % (dt.datetime.fromtimestamp(r["first"]).strftime("%m-%dT%H:%M"),
                          dt.datetime.fromtimestamp(r["last"]).strftime("%m-%dT%H:%M"))
        print("%s %s req=%d ctx/req=%dk ctx-max=%dk spikes=%d calls/msg=%.1f req/human=%s "
              "ro-streak=%d" % (sid[:8], span, r["req"], _k(r["med"]), _k(r["max"]),
                                r["spikes"], r["calls"],
                                ("%.1f" % (r["req"] / r["humans"])) if r["humans"] else "n/a",
                                r["ro"]))
    print("sessions=%d median-ctx/req=%dk over300k=%d"
          % (len(meds), _k(statistics.median(meds)) if meds else 0, over))
    return 0


def main(argv):
    if not argv:
        try:
            return hook()
        except Exception:                    # noqa: BLE001 — 触点永不非零退出、永不吐半个字节
            return 0
    if argv[0] != "--report" or len(argv) < 2:
        sys.stderr.write("usage: session-economics.py --report <transcript-dir> [--days N]\n")
        return 2
    days = 14
    if len(argv) >= 4 and argv[2] == "--days":
        days = int(argv[3])
    return report(argv[1], days)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
