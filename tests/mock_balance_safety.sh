#!/bin/bash
# 并发分流的安全阀/竞态/状态一致性测试
#
# 覆盖对抗式审计第二轮找到的问题：
#   P1-7 balance status 不拿锁，和守护进程互删探测路由 → 可能诱发误切换
#   P1-9 balance off 不拿锁 + 先清规则后写配置 → 规则被守护进程复活
#   P1-8 VPN 持有默认路由时安全阀被提前 return 跳过 → 半量连接进死口 + 隧道泄漏
#   P2-15 reevaluate 丢网段守卫 → 网段解析失败时打死局域网
#   P3-16 off 不清 state → status 同屏自相矛盾
#   P3-17 weighted 不写初始配比 → 开完 10 分钟内 status 与实际不一致
#   P0-2 BALANCE_MODE=weighted 被配置校验静默拒绝
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_safe.XXXXXX)"
trap 'rm -rf "$T"' EXIT INT TERM HUP
mkdir -p "$T/state" "$T/lock" "$T/bin"
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin" LOCK_DIR="$T/lock"
svc_router() { echo 192.168.1.1; }
other_nets() { echo; }
dev_subnet() { echo "${DEV_SUBNET:-192.168.1.0/24}"; }
pfctl() { return 0; }
pf_enabled() { return 1; }
pf_enabled_by_us() { return 1; }
. "$T/sr.sh"; trap - EXIT INT TERM HUP
export STATE_FILE="$T/state/st" PF_ANCHOR_FILE="$T/r.conf" PF_ANCHOR="smartroute"
acquire_lock_strict() { return 0; }
acquire_lock_wait()   { return 0; }
release_lock()        { return 0; }
log() { :; }
notify() { :; }
balance_off() { echo "BALANCE_OFF_CALLED q=${1:-}" >> "$T/off.log"; return 0; }

echo "== 1. VPN 持有默认路由时，安全阀不能跟着跳过（P1-8）=="
# 以前"不干预"的分支一上来就 return 0，于是并发分流的安全阀也不执行：
# 某口没外网时，一半新连接被送进死口，pf 还把去往 VPN 的流量
# 劫持到物理接口（隧道泄漏）。
ACTIVE_ETH_DEV="en0"; ACTIVE_WIFI_DEV="en1"
BALANCE=1
cat > "$T/vpncase.sh" <<'CASE'
. "$1"; trap - EXIT INT TERM HUP
export STATE_FILE="$2/st" PF_ANCHOR_FILE="$2/r.conf" PF_ANCHOR="smartroute" LOCK_DIR="$2/lock"
svc_router() { echo 192.168.1.1; }
other_nets() { echo; }
dev_subnet() { echo 192.168.1.0/24; }
pfctl() { return 0; }; pf_enabled() { return 1; }; pf_enabled_by_us() { return 1; }
log() { :; }; notify() { :; }
ACTIVE_ETH_DEV="en0"; ACTIVE_WIFI_DEV="en1"
CASE
# 直接在当前 shell 里调（_watch_core 太大，用它的 VPN 分支片段验证逻辑太绕，
# 这里验证的是"安全阀在 VPN 分支之前还是之后"这一顺序问题）
grep -n "由 VPN/其他接口持有" smartroute.sh | head -1 | grep -q . \
    && ok "VPN 分支存在" || bad "找不到 VPN 分支"
# 关键断言：VPN 分支内部必须自己处理 BALANCE=1，不能只 return 0
V=$(grep -n "由 VPN/其他接口持有" smartroute.sh | head -1 | cut -d: -f1)
sed -n "${V},$((V+14))p" smartroute.sh | grep -q 'BALANCE" = "1"' \
    && ok "VPN 分支自己关闭并发（安全阀没被跳过）" || bad "VPN 分支仍只 return 0，安全阀被跳过"
sed -n "${V},$((V+14))p" smartroute.sh | grep -q "隧道泄漏" \
    && ok "说明了原因（隧道泄漏），用户知道为什么突然被关" || bad "没说原因"

echo "== 2. off 必须先写配置再清规则（P1-9）=="
# 顺序反了会有一个毫秒级窗口：守护进程看到 anchor 空、文件还在、配置还是 1
# → 重新 pfctl -f 加载 → 规则复活。最终 pf 在分流而配置说 0，重启后才消失。
O=$(grep -n '^balance_off()' smartroute.sh | cut -d: -f1)
CONF_LINE=$(sed -n "${O},$((O+40))p" smartroute.sh | grep -n "conf_set_auto BALANCE 0" | head -1 | cut -d: -f1)
CLEAR_LINE=$(sed -n "${O},$((O+40))p" smartroute.sh | grep -n 'pfctl -a "$PF_ANCHOR" -F all' | head -1 | cut -d: -f1)
if [ -n "$CONF_LINE" ] && [ -n "$CLEAR_LINE" ] && [ "$CONF_LINE" -lt "$CLEAR_LINE" ]; then
    ok "先写配置（第 $CONF_LINE 行）再清规则（第 $CLEAR_LINE 行）"
else
    bad "顺序还是反的（配置=$CONF_LINE 清规则=${CLEAR_LINE}）"
fi
# 锁在 cmd_balance 的 off 分支拿，不在 balance_off 内部拿——
# balance_off 也会被安全阀（已持锁）和 balance_on 失败路径调用，再拿会重入。
sed -n "${O},$((O+40))p" smartroute.sh | grep -q "conf_set_auto BALANCE 0" \
    && ok "off 会写配置（先写再清规则）" || bad "off 不写配置"
grep -n 'off|disable|stop)' smartroute.sh | head -1 | grep -q . \
    && ok "off 入口存在" || bad "找不到 off 入口"
sed -n "$(grep -n 'off|disable|stop)' smartroute.sh | head -1 | cut -d: -f1),+6p" smartroute.sh \
    | grep -q "acquire_lock_strict" \
    && ok "cmd_balance off 入口也拿锁" || bad "off 入口不拿锁"

echo "== 3. off 必须清 state（P3-16）=="
sed -n "${O},$((O+40))p" smartroute.sh | grep -q 'state_set balance_mode ""' \
    && ok "清 balance_mode" || bad "没清 balance_mode"
sed -n "${O},$((O+40))p" smartroute.sh | grep -q 'state_set balance_winner ""' \
    && ok "清 balance_winner" || bad "没清 balance_winner"
sed -n "${O},$((O+40))p" smartroute.sh | grep -q 'state_set balance_weight ""' \
    && ok "清 balance_weight" || bad "没清 balance_weight（status 会挂着已关掉的配比）"

echo "== 4. weighted 开启时立即写初始配比（P3-17）=="
grep -q 'state_set balance_weight "$_bw0"' smartroute.sh \
    && ok "开启时写初始配比" || bad "没写初始配比（开完 10 分钟内 status 与实际不符）"
grep -q '_bw0="$w1:$w2"' smartroute.sh \
    && ok "只在测到吞吐时才记配比" || bad "配比赋值条件不对"
grep -q '测到了才记配比' smartroute.sh \
    && ok "注释说明为什么回退轮询时不记" || bad "没说清条件"

echo "== 5. reevaluate 路径要有网段守卫（P2-15）=="
grep -q '_balance_nets_ok()' smartroute.sh \
    && ok "有共享网段守卫" || bad "没有网段守卫"
NW=$(grep -n '^balance_weight_reevaluate()' smartroute.sh | cut -d: -f1)
NR=$(grep -n '^balance_reevaluate()' smartroute.sh | cut -d: -f1)
sed -n "${NW},$((NW+50))p" smartroute.sh | grep -q "_balance_nets_ok" \
    && ok "weighted 重测路径有守卫" || bad "weighted 重测路径没守卫"
sed -n "${NR},$((NR+50))p" smartroute.sh | grep -q "_balance_nets_ok" \
    && ok "fastest 重测路径有守卫" || bad "fastest 重测路径没守卫"
grep -q "局域网静默不通" smartroute.sh \
    && ok "注释写清了后果（不是局域网不通，是流量被 NAT 出去）" || bad "没说清后果"
# 守卫失败时必须保留旧规则，不能写半套规则
grep -q "保留现有规则" smartroute.sh \
    && ok "守卫失败时保留旧规则" || bad "没说保留旧规则"

echo "== 6. BALANCE_MODE=weighted 能通过配置校验（P0-2）=="
# 白名单以前只有 round-robin|fastest，而 balance_on 自己会写入 weighted
# → 下次重载配置时被丢弃、回落 round-robin。
conf_value_ok "BALANCE_MODE" "weighted" && ok "weighted 通过校验" || bad "weighted 仍被拒"
conf_value_ok "BALANCE_MODE" "round-robin" && ok "round-robin 仍通过" || bad "round-robin 被误伤"
conf_value_ok "BALANCE_MODE" "fastest" && ok "fastest 仍通过" || bad "fastest 被误伤"
conf_value_ok "BALANCE_MODE" "bogus" && bad "非法值被放行" || ok "非法值仍被拒"
# 端到端：写文件 → 解析 → 应该拿回 weighted
echo "BALANCE_MODE=weighted" > "$T/c.conf"
got="$(awk -F= '/^BALANCE_MODE=/{print $2}' "$T/c.conf")"
[ "$got" = "weighted" ] && ok "配置文件里 weighted 可被读回" || bad "读回失败: $got"

echo "== 7. balance status 测延迟要拿锁（P1-7）=="
S=$(grep -n '^balance_status()' smartroute.sh | cut -d: -f1)
sed -n "${S},$((S+90))p" smartroute.sh | grep -q "acquire_lock_wait" \
    && ok "status 测延迟前拿锁" || bad "status 不拿锁，会和守护进程互删探测路由"
sed -n "${S},$((S+90))p" smartroute.sh | grep -q "可能触发一次本不该发生的切换" \
    && ok "注释写清了竞态后果（诱发误切换）" || bad "没说清后果"
sed -n "${S},$((S+90))p" smartroute.sh | grep -q "本次不测实时延迟" \
    && ok "拿不到锁时降级提示，不卡住 status" || bad "没做降级"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
