#!/bin/bash
# 回归测试：cmd_watch speed 分支的「变慢预警」必须真的生效
#
# 曾经的病灶（smartroute.sh 续行中间插了 22 行注释）：
#
#     if [ -n "$_lc" ] && [ -n "$_lo" ] \
#        && awk -v a="$_lc" -v b="$_lo" -v r="$LATENCY_DEGRADE_RATIO" \
#        # ⚠️ 必须写成 (b+0)*r，不能写 b+0*r：      ← 注释嵌在行续符之后
#        # ...（共 22 行注释）
#        'BEGIN{ exit !(a+0 > (b+0)*r) }'; then
#
# bash 的词法：`\<newline>` 把下一行接进来，而 `#` 开始的注释一直吃到
# **逻辑行**末尾。于是 1460 行末尾的反斜杠 + 1461 行的 `#` 合并成的逻辑行是
#
#     ... && awk -v a=... -v r="$LATENCY_DEGRADE_RATIO" # ⚠️ …
#
# awk 的**程序文本不见了**；`; then` 也被注释吞掉。bash 继续为这个 if 找
# `then`，跳过注释行后，把 awk 程序那一行解析成条件列表里的**下一条命令**：
#
#     [ -n "$_lc" ] && [ -n "$_lo" ] && awk -v … ; 'BEGIN{…}' ; then
#
# 后果（当时实测三件事同时发生）：
#   1) awk 以「没有程序」启动，打 "awk: no program given" 并非零退出；
#   2) 'BEGIN{…}' 被当成 shell 命令执行 → "command not found"；
#   3) 条件列表的退出码来自最后一条命令（127），**这个 if 恒为假**。
#
# 用户可见后果：speed 模式下「延迟变坏提前重测吞吐」整体失效。线路劣化后
# 最多要等 SPEED_RECHECK（默认 300 秒）才重测——注释里承诺的"不要等 5 分钟"
# 从来没有发生过。同时守护进程每 20 秒往 /var/log/smartroute.err 写两行噪音。
#
# 修法：把那 22 行注释整个移到 if 语句**外面**（命令保持连续），
# 并在原地留了一条"注释不许挪回续行中间"的警告。
#
# 本文件守三件事：
#   1. 劣化够悬殊 → 预警真的触发、真的提前重测（正向）
#   2. 差距不够 → 不触发，不能一有抖动就重下全量（反向，防另一个极端）
#   3. stderr 干净（原病灶的直接指纹）
#   4. 静态 lint：全脚本任何地方都不许再出现"续行块中间的整行注释"
#
# 运行: bash tests/mock_audit_degrade_warn.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

SRC="$(pwd)/smartroute.sh"
T="$(mktemp -d /tmp/sr_dw.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log" "$T/run"

# date 固定，缓存新鲜度才可控
cat > "$T/bin/date" <<'EOF'
#!/bin/bash
[ "${1:-}" = "+%s" ] && { echo "${MOCK_NOW:-1700000000}"; exit 0; }
exec /bin/date "$@"
EOF
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/"*

# 被测副本（入口之前的部分）
awk '/^# ---------------- 入口 ----------------/{exit} {print}' "$SRC" > "$T/sr.sh"

common='
    . "$SR_FILE"
    trap - EXIT INT TERM HUP
    export PATH="'$T'/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export LOG_FILE="'$T'/sr.log" STATE_FILE="'$T'/state/st" MOCK_CALLS="'$T'/calls"
    export STATE_WRITABLE=1 LOCK_DIR="'$T'/lock" MOCK_NOW=1700000000
    export NOTIFY=0 AUTO_WIFI_POWER=0 BALANCE=0 WIFI_FAILOVER=0 MODE=speed
    find_active() { ACTIVE_ETH_DEV=en0; ACTIVE_WIFI_DEV=en1
                    ACTIVE_ETH_SVC="Ethernet"; ACTIVE_WIFI_SVC="Wi-Fi"; }
    probe_dev() { printf "%s\n" "${MOCK_ETH_RES:-ok}" "${MOCK_WIFI_RES:-ok}"; }
    do_switch() { :; }
    default_dev() { echo "${MOCK_DEFAULT_DEV:-en0}"; }
    apply_rules() { :; }
    wifi_failover_if_needed() { :; }
    # 缓存新鲜时 ensure_throughput 会跳过测量；只有 _force 非空才会调用它。
    # 所以"被调用"本身就是 force 生效的证据。
    measure_throughput() { echo "measure_throughput dev=$1" >> "$MOCK_CALLS"; return 0; }
    measure_latency() { return 0; }
'

# $1=被测脚本 $2=lat_en0 $3=lat_en1 -> stdout+stderr 合并输出
run_watch() {
    export SR_FILE="$1"
    : > "$T/calls"; : > "$T/sr.log"; : > "$T/state/st"
    printf 'streak_eth=2\nstreak_wifi=2\n' > "$T/state/st"
    # 两个缓存都必须新鲜，否则 ensure_* 会真去测量：
    #   speed 新鲜（300s 内）→ 只有 _force 非空才会重测
    #   lat   新鲜（60s 内） → 不会真去 ping
    echo "speed_en0=12000000 1699999990" >> "$T/state/st"
    echo "speed_en1=12000000 1699999990" >> "$T/state/st"
    echo "lat_en0=$2 1699999990" >> "$T/state/st"
    echo "lat_en1=$3 1699999990" >> "$T/state/st"
    bash -c "$common
        export MOCK_DEFAULT_DEV=en0
        cmd_watch
    " 2>&1
}

echo "== 1. 劣化够悬殊（30ms vs 10ms，3 倍）→ 预警触发且提前重测 =="
out="$(run_watch "$T/sr.sh" 30 10)"
printf '%s\n' "$out" | sed 's/^/    | /'
echo "    --- 日志 ---"; sed 's/^/    | /' "$T/sr.log" 2>/dev/null
echo "    --- measure_throughput 调用 ---"; sed 's/^/    | /' "$T/calls" 2>/dev/null
grep -q "变慢预警" "$T/sr.log" \
    && ok "日志有变慢预警" || bad "变慢预警没有触发（30ms > 2×10ms，本该触发）"
[ -s "$T/calls" ] \
    && ok "缓存仍新鲜却重测了吞吐（说明 _force 生效）" || bad "没有提前重测吞吐：劣化要等 SPEED_RECHECK 300s 才发现"

echo "== 2. 原病灶的直接指纹：stderr 必须干净 =="
# 修好之前这里固定出现两行：
#   awk: no program given
#   BEGIN{ exit !(a+0 > (b+0)*r) }: command not found
printf '%s\n' "$out" | grep -q "command not found" \
    && bad "stderr 仍有 'command not found'（续行被注释切断的老病复发）" \
    || ok "没有 'command not found'"
printf '%s\n' "$out" | grep -q "no program given" \
    && bad "stderr 仍有 'awk: no program given'" || ok "没有 'awk: no program given'"
printf '%s\n' "$out" | grep -q "integer expression\|syntax error\|unexpected" \
    && bad "stderr 有其它 shell/awk 错误" || ok "没有其它 shell/awk 错误"

echo "== 3. 反向：差距不够（13.4 vs 12.8，1.05 倍）→ 不触发 =="
# 这是修好之前**假触发**的那组数。若条件写得比设计松（比如漏了括号、
# 或阈值比较方向写反），这一组会重新开始每分钟重下 3 次全量。
out3="$(run_watch "$T/sr.sh" 13.4 12.8)"
printf '%s\n' "$out3" | sed 's/^/    | /'
echo "    --- 日志 ---"; sed 's/^/    | /' "$T/sr.log" 2>/dev/null
grep -q "变慢预警" "$T/sr.log" \
    && bad "1.05 倍也触发预警（阈值比较方向错成'任意快一点就重测'）" \
    || ok "1.05 倍不触发（13.4 < 2×12.8=25.6，符合设计意图）"
[ -s "$T/calls" ] \
    && bad "不该重测却重测了（带宽白烧）" || ok "缓存新鲜且未劣化 → 不重测"

echo "== 4. 静态 lint：续行块中间不许有整行注释 =="
# 行为测试只能覆盖"被 mock 到的那一条路径"。这条 lint 守的是全脚本：
# 任何人日后在别处写 `cmd \` + 注释 + `参数` 都会被拦住。
# 用 Python 而不是 grep：需要跟踪续行状态，grep 表达不了。
bad_lines="$(python3 - "$SRC" <<'PY'
import sys
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
in_cont = False
start = 0
hits = []
for idx, ln in enumerate(lines, 1):
    s = ln.strip()
    if not in_cont:
        if s.endswith('\\'):
            in_cont, start = True, idx
        continue
    if s.startswith('#'):
        hits.append('行 %d（续行块起于行 %d）' % (idx, start))
        in_cont = False
        continue
    if not s.endswith('\\'):
        in_cont = False
print('; '.join(hits))
PY
)"
[ -z "$bad_lines" ] \
    && ok "全脚本没有'续行块中间的整行注释'" \
    || bad "仍有续行块中间插注释：$bad_lines"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]
