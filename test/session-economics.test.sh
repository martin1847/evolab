#!/usr/bin/env bash
# session-economics — 触点（UserPromptSubmit 一行 additionalContext）与读数（--report）两个面。
#
# 头号断言 ①：被编排仓、上下文越过 300k ⇒ stdout 恰一行 schema 合法的 additionalContext。
# 它的两个阴性对照必须同时在，否则 ① 可以被一个「无条件说话」的实现骗绿：
#   ⑤ 身份——同形载荷、cwd 换成没人编排的仓 ⇒ 零字节（配一条同 transcript 的 paired green）；
#   ⑩ 阈值——被编排仓、刚回复完、上下文 200k ⇒ 零字节（去掉阈值比较的变体在此必红）。
# 其余：每档每 session 一次 ②③、闲置只提一次 ④、单字段坏样本 ⑥、同 id 多行去重 ⑦（累加 / 取最大
# 都红）、读数逐项 ⑧、retro-check 第 12 检三态 ⑨、压缩边界之后才算数 ⑫（配 paired green）、边界后
# 档位重置 ⑬、文案动作是 `/compact` ⑭。
# 夹具全是脚本里现写的合成 transcript：真 transcript 是主理人的会话记录，不是测试输入。
# 沙箱自带 run dir（lib-testkit 的 AGENT_WATCH_DIR）与 HOME，真 /tmp/agent-watch-run 一次都不碰。
set -u
cd "$(dirname "$0")"
. ./lib-testkit.sh

SE="$REPO_ROOT/skills/cto-orchestration/references/session-economics.py"
REFS="$REPO_ROOT/skills/cto-orchestration/references"

echo "== session-economics =="

# 缺工具是验证失败，不是绿色跳过：谓词比的是 git common dir，没有 git 这里一条也判不了。
for t in python3 git; do
  command -v "$t" >/dev/null 2>&1 || { echo "  FAIL REQUIRED TOOL MISSING: $t"; exit 1; }
done

sandbox_new
trap 'sandbox_clean' EXIT

ORCH="$SANDBOX/orch"; PLAIN="$SANDBOX/plain"; TX="$SANDBOX/tx"
mkdir -p "$ORCH" "$PLAIN" "$TX"
git -C "$ORCH" init -q; git -C "$PLAIN" init -q

# 被编排的证据：本夹具自己 run dir 今日分片里的一行 start（同 cto-guard-edit.test.sh 的 ledger_row）。
ledger_row() { # $1 cwd
  python3 -c 'import json, os, sys
print(json.dumps({"ts": "2026-09-23T00:00:00.000Z", "event": "start", "name": "fixture",
                  "session_id": "s", "attempt": "a", "engine": "omp",
                  "cwd": os.path.realpath(sys.argv[1])}))' "$1" \
    >> "$WATCH_RUN_DIR/phase-ledger-$(date -u +%Y%m%d).jsonl"
}
ledger_row "$ORCH"

# 合成 transcript：一条 user + 一条带 usage 的 assistant（ctx = input + cache_read + cache_creation）。
tx_one() { # $1 path  $2 ctx-tokens  $3 minutes-ago
  python3 -c 'import datetime as dt, json, sys
path, ctx, ago = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
ts = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
rows = [{"type": "user", "timestamp": ts, "message": {"role": "user", "content": "干活"}},
        {"type": "assistant", "timestamp": ts,
         "message": {"id": "msg_1", "role": "assistant",
                     "content": [{"type": "text", "text": "ok"}],
                     "usage": {"input_tokens": 10, "cache_read_input_tokens": ctx - 10,
                               "cache_creation_input_tokens": 0, "output_tokens": 5}}}]
open(path, "w").write("".join(json.dumps(r) + "\n" for r in rows))' "$1" "$2" "$3"
}

# 压缩边界夹具：pre 那条 assistant ＋可选的 system/compact_boundary（＋紧随的 isCompactSummary user
# 行，它不是判据、在这里只为形态真实）＋可选的边界之后一条 assistant。压缩后第一条 prompt 的真实形态
# = boundary 1 / post 0：尾部最后一条 assistant 还是压缩前那条。
tx_compact() { # $1 path  $2 pre-ctx  $3 boundary(1/0)  $4 post-ctx(0=无)
  python3 -c 'import datetime as dt, json, sys
path, pre, boundary, post = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1", int(sys.argv[4])
now = dt.datetime.now(dt.timezone.utc)
def stamp(ago):
    return (now - dt.timedelta(minutes=ago)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def amsg(i, ctx, ago):
    return {"type": "assistant", "timestamp": stamp(ago),
            "message": {"id": "msg_%d" % i, "role": "assistant",
                        "content": [{"type": "text", "text": "ok"}],
                        "usage": {"input_tokens": 10, "cache_read_input_tokens": ctx - 10,
                                  "cache_creation_input_tokens": 0, "output_tokens": 5}}}
rows = [{"type": "user", "timestamp": stamp(9), "message": {"role": "user", "content": "干活"}},
        amsg(1, pre, 8)]
if boundary:
    rows.append({"type": "system", "subtype": "compact_boundary", "timestamp": stamp(4),
                 "content": "Conversation compacted", "level": "info",
                 "compactMetadata": {"trigger": "manual", "preTokens": pre}})
    rows.append({"type": "user", "timestamp": stamp(4), "isCompactSummary": True,
                 "message": {"role": "user", "content": "This session is being continued…"}})
if post:
    rows.append(amsg(2, post, 1))
open(path, "w").write("".join(json.dumps(r) + "\n" for r in rows))' "$1" "$2" "$3" "$4"
}

payload() { # $1 session  $2 cwd  $3 transcript  [$4 event]
  python3 -c 'import json, sys
print(json.dumps({"hook_event_name": sys.argv[4], "session_id": sys.argv[1],
                  "cwd": sys.argv[2], "transcript_path": sys.argv[3]}))' \
    "$1" "$2" "$3" "${4:-UserPromptSubmit}"
}
fire() { # $1 session  $2 cwd  $3 transcript  [$4 event] -> OUT / RC
  OUT="$(payload "$1" "$2" "$3" "${4:-UserPromptSubmit}" | python3 "$SE")"; RC=$?
}

chk_eq "script is executable" 1 "$([ -x "$SE" ] && echo 1 || echo 0)"

# ── ① 头号断言：被编排仓越过 300k 档 ⇒ 一行 additionalContext ─────────────────────────────
T1="$TX/t1.jsonl"; tx_one "$T1" 320000 0
fire s1 "$ORCH" "$T1"
chk_eq "① 越档提醒 rc=0" 0 "$RC"
chk_contains "① 打的是 UserPromptSubmit 的 additionalContext" \
  '"hookEventName": "UserPromptSubmit"' "$OUT"
chk_contains "① 文案报当前上下文" "上下文 320k" "$OUT"
chk_contains "① 文案报触发的档位" "阈 300k" "$OUT"
chk_contains "① 文案给动作（收口即 /compact）" '收口即 `/compact`' "$OUT"
chk_eq "① 输出是一行" 1 "$(printf '%s\n' "$OUT" | grep -c .)"
chk_eq "① 输出是合法 JSON" 1 \
  "$(printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin); print(1)' 2>/dev/null || echo 0)"
chk_not_contains "① 不写 systemMessage（不抢用户可见通道）" "systemMessage" "$OUT"

# ── ② 每档每 session 只说一次 ──────────────────────────────────────────────────────────────
fire s1 "$ORCH" "$T1"
chk_eq "② 同 session 同档第二次静默" "0|" "$RC|$OUT"

# ── ③ 下一档仍然说 ────────────────────────────────────────────────────────────────────────
T3="$TX/t3.jsonl"; tx_one "$T3" 460000 0
fire s1 "$ORCH" "$T3"
chk_contains "③ 同 session 越到 450k 档再说一次" "阈 450k" "$OUT"

# ── ④ 闲置重缓存：>55 分钟且 ≥150k，同一次闲置只提一次 ───────────────────────────────────
T4="$TX/t4.jsonl"; tx_one "$T4" 200000 70
fire s4 "$ORCH" "$T4"
chk_contains "④ 闲置 70 分钟提醒" "闲置 70 分钟" "$OUT"
chk_contains "④ 文案给重缓存量级" "≈2×200k" "$OUT"
chk_not_contains "④ 200k 不触发档位提醒" "阈 300k" "$OUT"
fire s4 "$ORCH" "$T4"
chk_eq "④ 同一次闲置第二次静默" "0|" "$RC|$OUT"

# ── ⑤ 阴性对照·身份：同形载荷，cwd 换成没人编排的仓 ⇒ 零字节 ─────────────────────────────
# session 另起：沿用 ① 的 session 会被状态去重静默，那样这条控制什么都不证明。
fire s5 "$PLAIN" "$T1"
chk_eq "⑤ 非被编排仓一个字都不说" "0|" "$RC|$OUT"
fire s5b "$ORCH" "$T1"
chk_contains "⑤ PAIRED GREEN：同 transcript 在被编排仓仍然说" "上下文 320k" "$OUT"

# ── ⑩ 阴性对照·阈值：被编排仓、刚回复完、200k ⇒ 零字节 ───────────────────────────────────
T10="$TX/t10.jsonl"; tx_one "$T10" 200000 1
fire s10 "$ORCH" "$T10"
chk_eq "⑩ 没越档也没闲置就不说（无条件首提的变体在此红）" "0|" "$RC|$OUT"

# ── ⑪ 静默出口·持久化失败：状态文件路径被目录占住 ⇒ open() 抛 OSError ⇒ 零字节（codex R1 F1）────
T11="$TX/t11.jsonl"; tx_one "$T11" 320000 0
mkdir -p "$AGENT_WATCH_DIR/ctx-nudge/s11.json"
fire s11 "$ORCH" "$T11"
chk_eq "⑪ 状态写失败不发声（合同：任何异常路径零字节）" "0|" "$RC|$OUT"

# ── ⑫ 压缩边界之后才算数：边界后还没有 assistant ⇒ 压缩后第一条 prompt 零字节 ─────────────
# 旧读法在这个夹具上读到的正是压缩前那条 408k（0923 现场误报的那一条）。
T12="$TX/t12.jsonl"; tx_compact "$T12" 408000 1 0
fire s12 "$ORCH" "$T12"
chk_eq "⑫ 压缩后第一条 prompt 不说话（旧读法在此报 408k）" "0|" "$RC|$OUT"
T12B="$TX/t12b.jsonl"; tx_compact "$T12B" 408000 0 0
fire s12b "$ORCH" "$T12B"
chk_contains "⑫ PAIRED GREEN：同夹具去掉边界两行就说话（排除「永远静默」）" "上下文 408k" "$OUT"

# ── ⑬ 边界之后档位重置：压缩后是另一段上下文，同一档要能再提醒一次 ─────────────────────────
T13="$TX/t13.jsonl"; tx_compact "$T13" 320000 0 0
fire s13 "$ORCH" "$T13"
chk_contains "⑬ 边界前越 300k 提醒一次" "阈 300k" "$OUT"
tx_compact "$T13" 320000 1 320000        # 同一 session：补上边界 + 边界之后新的 320k assistant
fire s13 "$ORCH" "$T13"
chk_contains "⑬ 边界之后同一档再提醒一次" "阈 300k" "$OUT"
fire s13 "$ORCH" "$T13"
chk_eq "⑬ 同一个边界不重复提醒（compact_ts 没存住时此条红）" "0|" "$RC|$OUT"
T13C="$TX/t13c.jsonl"; tx_compact "$T13C" 320000 0 0
fire s13c "$ORCH" "$T13C"
chk_contains "⑬ 对照：无边界首次仍提醒" "阈 300k" "$OUT"
fire s13c "$ORCH" "$T13C"
chk_eq "⑬ 对照：无边界时第二次静默（重置不是无条件的）" "0|" "$RC|$OUT"

# ── ⑭ 文案给的动作是 `/compact`，不是「换会话」（主理人 0923：接得上 > 省 token）──────────────
T14="$TX/t14.jsonl"; tx_one "$T14" 320000 0
fire s14a "$ORCH" "$T14"
chk_contains "⑭ 档位文案的动作是 /compact" '收口即 `/compact`' "$OUT"
T14B="$TX/t14b.jsonl"; tx_one "$T14B" 200000 70
fire s14b "$ORCH" "$T14B"
chk_contains "⑭ 闲置文案的动作也是 /compact" '先 `/compact`' "$OUT"
chk_eq "⑭ 脚本全文不再出现「换会话」" 0 "$(grep -c '换会话' "$SE")"

# ── ⑥ 单字段坏样本：每次只坏一个字段，三次都零字节 + rc=0 ────────────────────────────────
fire s6a "$ORCH" "$T1" SessionStart
chk_eq "⑥ 别的事件名静默" "0|" "$RC|$OUT"
OUT="$(printf 'not json at all' | python3 "$SE")"; RC=$?
chk_eq "⑥ stdin 非 JSON 静默" "0|" "$RC|$OUT"
fire s6c "$ORCH" "$TX/missing.jsonl"
chk_eq "⑥ transcript 不存在静默" "0|" "$RC|$OUT"

# ── ⑦ 同 message.id 多行去重：最后一行是这次调用的账，累加 / 取最大都错 ──────────────────
T7="$TX/t7.jsonl"
python3 -c 'import datetime as dt, json, sys
ts = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
rows = []
for ctx in (100000, 400000, 320000):
    rows.append({"type": "assistant", "timestamp": ts,
                 "message": {"id": "msg_same", "role": "assistant",
                             "content": [{"type": "text", "text": "block"}],
                             "usage": {"input_tokens": 10, "cache_read_input_tokens": ctx - 10,
                                       "cache_creation_input_tokens": 0}}})
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))' "$T7"
fire s7 "$ORCH" "$T7"
chk_contains "⑦ 同 id 三行取最后一行" "上下文 320k" "$OUT"
chk_not_contains "⑦ 不累加（820k 会红）" "820k" "$OUT"
chk_not_contains "⑦ 不取最大（400k 会红）" "400k" "$OUT"

# ── ⑧ 读数模式：两个会话逐项等于预算值 ───────────────────────────────────────────────────
# A: 5 条 assistant，ctx 200/300/350/400/500k ⇒ 中位 350k、max 500k；一条 cache_creation 150k ⇒
#    spikes=1；每条恰一个 tool_use ⇒ calls/msg=1.0；前 3 条是只读 Bash、后 2 条写 ⇒ ro-streak=3；
#    人类 prompt 2 条（tool_result 回灌与 task-notification 唤醒都不算）⇒ req/human=2.5。
# B: 5 条 120k、无工具 ⇒ calls/msg=0.0、ro-streak=0、req/human=5.0。
RPT="$SANDBOX/projects"; mkdir -p "$RPT"
python3 -c 'import datetime as dt, json, os, sys
out = sys.argv[1]
now = dt.datetime.now(dt.timezone.utc)
def stamp(mins):
    return (now - dt.timedelta(minutes=mins)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def amsg(i, ctx, creat, tool, mins):
    m = {"id": "a%d" % i, "role": "assistant", "content": [], "usage":
         {"input_tokens": 10, "cache_read_input_tokens": ctx - 10 - creat,
          "cache_creation_input_tokens": creat, "output_tokens": 7}}
    if tool:
        m["content"].append({"type": "tool_use", "name": "Bash", "input": {"command": tool}})
    return {"type": "assistant", "timestamp": stamp(mins), "message": m}
rows = [{"type": "user", "timestamp": stamp(60), "message": {"role": "user", "content": "开工"}}]
ro, wr = "wc -l foo.txt", "git commit -m x"
for i, (ctx, creat, tool) in enumerate([(200000, 0, ro), (300000, 0, ro), (350000, 150000, ro),
                                        (400000, 0, wr), (500000, 0, wr)]):
    rows.append(amsg(i, ctx, creat, tool, 50 - i))
    rows.append({"type": "user", "timestamp": stamp(50 - i),
                 "message": {"role": "user", "content": [{"type": "tool_result", "content": "x"}]}})
rows.append({"type": "user", "timestamp": stamp(40),
             "message": {"role": "user", "content": "task-notification: 席位完工"}})
rows.append({"type": "user", "timestamp": stamp(39), "message": {"role": "user", "content": "继续"}})
open(os.path.join(out, "aaaaaaaa-1111.jsonl"), "w").write(
    "".join(json.dumps(r) + "\n" for r in rows))
rows = [{"type": "user", "timestamp": stamp(30), "message": {"role": "user", "content": "小活"}}]
rows += [amsg(i, 120000, 0, None, 29 - i) for i in range(5)]
open(os.path.join(out, "bbbbbbbb-2222.jsonl"), "w").write(
    "".join(json.dumps(r) + "\n" for r in rows))
# 窗口外的会话与不足 5 条的会话都不出行；一个读不出的 "文件" 出一行 [skip] 且不打断其余
open(os.path.join(out, "cccccccc-3333.jsonl"), "w").write(
    "".join(json.dumps(amsg(i, 900000, 0, None, 29 - i)) + "\n" for i in range(2)))
os.makedirs(os.path.join(out, "deadbeef-dir.jsonl"), exist_ok=True)' "$RPT"

REP="$(python3 "$SE" --report "$RPT" --days 14)"; RC=$?
chk_eq "⑧ 读数 rc=0" 0 "$RC"
# 会话名与时间跨度单独断言：跨度是本地时区渲染的，把它焊进逐项 needle 只会让断言脆，不会让它更严。
A_LINE="$(printf '%s\n' "$REP" | grep '^aaaaaaa')"
B_LINE="$(printf '%s\n' "$REP" | grep '^bbbbbbb')"
chk_eq "⑧ A 会话恰一行" 1 "$(printf '%s\n' "$A_LINE" | grep -c .)"
chk_contains "⑧ A 会话行逐项" \
  "req=5 ctx/req=350k ctx-max=500k spikes=1 calls/msg=1.0 req/human=2.5 ro-streak=3" "$A_LINE"
chk_contains "⑧ A 会话行带时间跨度" "→" "$A_LINE"
chk_contains "⑧ B 会话行逐项" \
  "req=5 ctx/req=120k ctx-max=120k spikes=0 calls/msg=0.0 req/human=5.0 ro-streak=0" "$B_LINE"
chk_not_contains "⑧ 不足 5 条的会话不出行" "cccccccc" "$REP"
chk_contains "⑧ 读不出的会话只 skip 一行" "[skip] deadbeef" "$REP"
chk_contains "⑧ 汇总行" "sessions=2 median-ctx/req=235k over300k=1" "$REP"
REP0="$(python3 "$SE" --report "$SANDBOX/no-such-dir")"; RC=$?
chk_eq "⑧ 目录不存在 = skip, rc=0" 0 "$RC"
chk_contains "⑧ skip 说明是哪一个目录" "[skip] $SANDBOX/no-such-dir" "$REP0"

# ── ⑨ retro-check 第 12 检三态（沙箱 sibling 副本 + 沙箱 HOME；真文件一个字节不动）─────────
SB="$SANDBOX/rc"; mkdir -p "$SB"
cp -R "$REFS" "$SB/references"
RCHOME="$SB/home"; RCREPO="$SB/repo"
mkdir -p "$RCHOME" "$RCREPO/docs"
git init -q -b main "$RCREPO"
printf 'Last rewritten: %s\n' "$(date +%F)" > "$RCREPO/docs/ACTIVE_CONTEXT.md"
( cd "$RCREPO" && git add -A && git commit -qm init ) >/dev/null 2>&1
SAN="$(cd "$RCREPO" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
PROJ="$RCHOME/.claude/projects/$SAN"
check12() { # -> OUT12 = 第 12 检自己的输出行
  OUT12="$( cd "$RCREPO" && HOME="$RCHOME" AGENT_WATCH_DIR="$SB/no-agent-watch" \
            bash "$SB/references/retro-check.sh" --base main --docs docs 2>&1 \
            | sed -n '/^12)/,/^== result/p' )"
}
check12
chk_contains "⑨ 目录不存在 ⇒ skip" "[skip]" "$OUT12"
chk_not_contains "⑨ skip 不是 FAIL" "[FAIL]" "$OUT12"
mkdir -p "$PROJ"; find "$RPT" -maxdepth 1 -type f -name '*.jsonl' -exec cp {} "$PROJ/" \;
check12
chk_contains "⑨ 有读数且 over300k>0 ⇒ warn 点名会话数" "[warn] 1 个会话" "$OUT12"
chk_contains "⑨ warn 原样打印读数行" "ctx/req=350k" "$OUT12"
chk_not_contains "⑨ warn 不是 FAIL" "[FAIL]" "$OUT12"
printf 'raise SystemExit(3)\n' > "$SB/references/session-economics.py"
check12
chk_contains "⑨ 量具坏 ⇒ FAIL" "[FAIL]" "$OUT12"
chk_contains "⑨ FAIL 点名 rc" "rc=3" "$OUT12"

summary
