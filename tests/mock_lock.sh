#!/bin/bash
# 主机路由的互斥：measure/quality/test 不能和守护进程的探测并发
#
# 背景：probe_dev 和 measure_latency 都会为同一批目标加主机路由
# （route add -host <目标> <设备> <网关>），并且都会调用 cleanup_probe_routes。
# 两个进程并发时，一方的 cleanup 会把另一方刚加的路由删掉，
# 于是探测/测延迟改走默认路由——**测到的是另一个接口**。
#
# 后果不是"测速数字不准"这么轻：错误的可用性判定会触发一次本来不该发生
# 的切换，用户感受是"网络莫名其妙断了一下"。
#
# 运行: bash tests/mock_lock.sh
SRC="$(cd "$(dirname "$0")/.." && pwd)/smartroute.sh"
checks=0; failures=0
ok()  { checks=$((checks+1)); printf '  ✓ %s\n' "$1"; }
bad() { failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

echo "== 1. 三个动路由的命令都必须先抢锁 =="
for cmd in cmd_measure cmd_quality cmd_test; do
    if awk "/^${cmd}\(\)/,/^}/" "$SRC" | grep -q 'acquire_lock_wait'; then
        ok "$cmd 抢锁后才动路由"
    else
        bad "$cmd 没抢锁就动主机路由（会和守护进程互相删路由）"
    fi
done

echo "== 2. 守护进程仍用安静跳过（不能被等待拖住）=="
# watch 必须继续用 acquire_lock（忙就 exit 0）。改成等待会让 launchctl
# 每次调用都阻塞，而 StartInterval 是 20 秒——等超过 20 秒就会堆叠。
# 锁是在 main() 的分派表里拿的（watch|once|run) acquire_lock; cmd_watch ），
# 不在 cmd_watch 函数体内。第一版去 awk cmd_watch 的函数体，当然找不到。
grep -q 'watch|once|run) acquire_lock; cmd_watch' "$SRC" \
    && ok "watch 仍用安静跳过的 acquire_lock（忙就 exit 0）" \
    || bad "watch 的锁行为被改了（改成等待会阻塞 launchctl）"

echo "== 3. 等待有上限，不会无限等 =="
if awk '/^acquire_lock_wait\(\)/,/^}/' "$SRC" | grep -q 'deadline'; then
    ok "acquire_lock_wait 有截止时间"
else
    bad "acquire_lock_wait 没有截止时间，可能永久挂住"
fi
awk '/^acquire_lock_wait\(\)/,/^}/' "$SRC" | grep -q 'return 1' \
    && ok "等不到返回失败（调用方 die，不硬闯）" || bad "等不到还继续执行"

echo "== 4. 抢不到锁时必须明确告知，不能静默继续 =="
for cmd in cmd_measure cmd_quality cmd_test; do
    if awk "/^${cmd}\(\)/,/^}/" "$SRC" | grep -q 'acquire_lock_wait.*||.*die'; then
        ok "$cmd 抢不到锁时报错退出"
    else
        bad "$cmd 抢不到锁还继续动路由"
    fi
done

echo "== 5. 三种抢锁方式共用同一套判定（不会各自漂移）=="
# 以前三个函数各写一遍 mkdir/查 pid/清残留，语义容易不一致。
if [ "$(grep -c '_lock_try' "$SRC")" -ge 4 ]; then
    ok "acquire_lock / strict / wait 都基于 _lock_try"
else
    bad "抢锁逻辑没有收敛到一个函数"
fi
awk '/^acquire_lock\(\)/,/^}/' "$SRC" | grep -q '_lock_try' \
    && ok "acquire_lock 基于 _lock_try" || bad "acquire_lock 仍是独立实现"
awk '/^acquire_lock_strict\(\)/,/^}/' "$SRC" | grep -q '_lock_try' \
    && ok "acquire_lock_strict 基于 _lock_try" || bad "strict 仍是独立实现"

echo "== 6. 陈旧锁要能恢复（上次被 SIGKILL 会留下锁）=="
awk '/^_lock_try\(\)/,/^}/' "$SRC" | grep -q 'kill -0' \
    && ok "会检查持有者是否还活着" || bad "不检查持有者，陈旧锁会永久卡住"
awk '/^_lock_try\(\)/,/^}/' "$SRC" | grep -q 'rm -rf "\$LOCK_DIR"' \
    && ok "持有者已死时清掉残留锁" || bad "不清陈旧锁，之后所有命令都拿不到锁"

echo "== 7. 锁的释放不能漏（否则一次崩溃永久卡住）=="
grep -q "rm -rf \"\$LOCK_DIR\"" "$SRC" \
    && ok "退出时会删掉锁目录" || bad "退出不删锁，崩溃后永久卡住"
grep -q "trap.*EXIT INT TERM HUP" "$SRC" \
    && ok "EXIT/INT/TERM/HUP 都挂了解释放" || bad "信号没全覆盖，TERM 杀不掉会留锁"

echo "== 8. 非 root 不能被锁拦住（锁目录建不出来）=="
# 锁目录在 /var/run 下属 root。非 root 建不出它，_lock_try 会一直失败，
# 白等满超时后报「另一个操作正在进行」——而真相是根本没有锁可用。
# 这会把 App 的体检/测延迟页整个打死（App 调 quality 不带 sudo）。
# 实测踩到过：改完之后 bash smartroute.sh quality 直接报错。
seg="$(awk '/^acquire_lock_wait\(\)/,/^}/' "$SRC")"
printf '%s' "$seg" | grep -q 'id -u' && printf '%s' "$seg" | grep -q -- '-ne 0' \
    && ok "非 root 且无锁目录时直接放行" || bad "非 root 会被不存在的锁拦住"
printf '%s' "$seg" | grep -qF '[ ! -d "$LOCK_DIR" ]' \
    && ok "放行条件包含「锁目录不存在」" || bad "没判断锁目录是否存在"
printf '%s' "$seg" | grep -q 'deadline' \
    && ok "有锁可争时仍然等待" || bad "有锁时不等了"

echo "== 9. 放行是安全的（非 root 确实不碰路由表）=="
# 互斥的目的只是保护主机路由增删，那件事需要 root。
# 三个命令在非 root 下都必须走「按当前默认路由」的分支。
awk '/^probe_dev\(\)/,/^}/' "$SRC" | grep -q '非 root：按当前默认路由探测' \
    && ok "probe_dev 非 root 不加主机路由" || bad "probe_dev 非 root 也动路由"
# measure_latency 的加路由条件是 root 且有网关，压平了查（分处两行）
printf '%s\n' "$(awk '/^measure_latency\(\)/,/^}/' "$SRC")" | tr '\n' ' ' | tr -s ' ' \
    | grep -q 'id -u.*-eq 0.*&&.*-n "$gw"' \
    && ok "measure_latency 只在 root 下加主机路由" || bad "measure_latency 非 root 也动路由"
awk '/^cmd_quality\(\)/,/^}/' "$SRC" | grep -q 'id -u' \
    && ok "cmd_quality 只在 root 下加主机路由" || bad "cmd_quality 非 root 也动路由"
# measure 本来就要 root，不受影响
awk '/^cmd_measure\(\)/,/^}/' "$SRC" | grep -q '测速需要 root' \
    && ok "measure 仍要求 root（它必须加路由才能分别测两个接口）" \
    || bad "measure 的 root 要求被去掉了"

echo ""
echo "结果: $((checks - failures)) 通过, $failures 失败"
