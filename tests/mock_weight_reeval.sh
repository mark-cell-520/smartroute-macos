#!/bin/bash
# weighted 模式的周期性重测
#
# 背景：权重原本只在 balance on 那一刻算一次，之后永不更新。可 Wi-Fi 的实际
# 吞吐一直在变（走远一点、信道拥塞、邻居开机），几分钟后 1:4 就失真了。
# 失真后果很直接：Wi-Fi 掉到比有线还慢时，4/5 的新连接还在往 Wi-Fi 送，
# 总吞吐反而低于单走有线——"开了并发比不开还慢"。
#
# 运行: bash tests/mock_weight_reeval.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_wr.XXXXXX)"
mkdir -p "$T/state" "$T/lock"
trap 'rm -rf "$T"' EXIT
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export ACTIVE_ETH_DEV=en0 ACTIVE_WIFI_DEV=en1 ACTIVE_ETH_SVC=Ethernet ACTIVE_WIFI_SVC=Wi-Fi
# 注意：PF_ANCHOR_FILE / STATE_FILE 故意**不在这里**导出。
# 脚本 source 时有无条件赋值，先导出会被覆盖成 /etc/pf.anchors/... 和
# /var/db/smartroute/state——前者非 root 写不进去（刷一屏 Operation not
# permitted），后者读出来的永远是空，测试就全假失败。
# 一律放到 source 之后再导出。
svc_router() { echo 192.168.1.1; }        # 两个接口同网关（本机实况）
other_nets() { echo; }
dev_subnet() { echo 192.168.1.0/24; }
eth_wifi_same_gateway() { return 0; }
pfctl() { return 0; }
pf_enabled() { return 1; }
notify() { :; }
log() { :; }
fmt_bps() { echo "$1 bps"; }
. "$T/sr.sh"
trap - EXIT INT TERM HUP
# 覆盖必须放在 source **之后**。放在之前会被脚本里的同名定义冲掉，
# 于是真实的 ensure_throughput 跑起来：它发现缓存不新鲜就真去测速
# （要下载），把刚删掉的 speed_en1 又填回去，"一边测不到"这条用例
# 就永远测不出来，而且测试还会偷偷跑真实下载、变得又慢又不确定。
ensure_throughput() { return 0; }         # 不真测速，直接用 state 里的值
# 必须放在 source 之后：见上面的注释。
export STATE_FILE="$T/state/st"
export PF_ANCHOR_FILE="$T/rules.conf"
export PF_ANCHOR="smartroute"

# 造一轮条件并触发重测。$1=旧权重 $2=eth 吞吐 $3=wifi 吞吐
mk() { state_set balance_weight "$1"; _metric_set speed_en0 "$2"; _metric_set speed_en1 "$3"
       : > "$T/rules.conf"; balance_weight_reevaluate; }
cnt() { grep -o -F "$1" "$T/rules.conf" | wc -l | tr -d ' '; }

echo "== 1. 配比要跟着实测吞吐变 =="
mk '1:1' 100000000 432000000
[ "$(state_get balance_weight)" = "1:4" ] && ok "100M:432M → 1:4（本机实况）" \
    || bad "配比错: $(state_get balance_weight)"
mk '1:4' 100000000 100000000
[ "$(state_get balance_weight)" = "4:4" ] && ok "等速 → 4:4" \
    || bad "配比错: $(state_get balance_weight)"
# 核心价值：Wi-Fi 掉到比有线还慢时，配比必须反过来
mk '1:4' 100000000 20000000
[ "$(state_get balance_weight)" = "4:1" ] && ok "Wi-Fi 掉到 20M → 4:1（配比反过来）" \
    || bad "配比没反过来: $(state_get balance_weight)"

echo "== 2. 权重未变则不重写规则 =="
# pfctl -f 会重建整张 anchor。虽然 pf 有状态、已有连接不断，但没必要每轮询
# 都重载一遍；只有真的变了才值得动。
mk '1:4' 100000000 432000000
[ -s "$T/rules.conf" ] && bad "权重没变却重写了规则" || ok "权重未变，未重写"

echo "== 3. 测不到时不动作 =="
# 删 key 不用 sed -i：状态值里含空格（"值 时间戳"），且不同 sed 实现对
# -i 加含空格路径的处理不一致，实测会报 "unescaped newline"。
# 用 awk 过滤重写，只动目标键。
del_key() {   # $1=要删的键
    [ -f "$STATE_FILE" ] || return 0
    awk -F= -v k="$1" '$1!=k' "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null \
        && mv "$STATE_FILE.tmp" "$STATE_FILE" 2>/dev/null
}
state_set balance_weight '9:9'
del_key speed_en1
: > "$T/rules.conf"; balance_weight_reevaluate
[ -s "$T/rules.conf" ] && bad "一边测不到还重写了" || ok "一边测不到时不动作"
del_key speed_en0; del_key speed_en1
: > "$T/rules.conf"; balance_weight_reevaluate
[ -s "$T/rules.conf" ] && bad "都测不到还重写" || ok "两边都测不到时不动作"

echo "== 4. 必须用 _metric_val 取吞吐，不能用 state_get =="
# _metric_set 存的是"值 时间戳"，state_get 原样返回、带着空格。
# 用 state_get 会让数字校验全部落空，于是永远不重写——功能静默失效，
# 表面上只是"配比没更新"，没有任何报错。
grep -q '_metric_val "speed_\$ACTIVE_ETH_DEV"' smartroute.sh \
    && ok "用 _metric_val（会去掉时间戳）" || bad "还在用 state_get，重测会静默失效"
grep -q 'state_get "speed_\$ACTIVE_ETH_DEV"' smartroute.sh \
    && bad "仍在用 state_get 取 speed" || ok "没有用 state_get 取 speed"

echo "== 5. 重写时同网段也必须带 NAT =="
# 见 mock_weighted 第 6 节：同网段不加 NAT，回程会涌向另一个接口，
# 下载就被钉死在慢的那条上。重测重写规则时同样不能漏。
mk '1:1' 100000000 432000000
[ "$(grep -c '^nat ' "$T/rules.conf")" -ge 2 ] && ok "重写的规则含 nat" \
    || bad "重写时漏了 NAT"

echo "== 6. write_pf_rules 只收 8 个参数，不该多传 same =="
# 多传不报错，但会让人以为要在这里维护 same；改子网判断时就会漏改。
grep -q 'write_pf_rules "\$ACTIVE_ETH_DEV" "\$eth_gw" "\$ACTIVE_WIFI_DEV" "\$wifi_gw" "\$excl" "" "\$w1" "\$w2" || return 1' smartroute.sh \
    && ok "按 8 参调用，没有多传 same" || bad "多传了参数或调用形式不对"

echo "== 7. balance_status 必须显示当前配比 =="
# 以前只打"轮询（两个接口交替）"，而 weighted 根本不是轮询——它把快的网关
# 在 route-to 列表里重复多次。显示成轮询会让用户以为两边一样多，
# 实际可能是 1:4，排查时完全对不上。而且配比是周期重测的，
# 用户需要看到当前值才知道守护进程有没有在工作。
state_set balance_mode weighted
state_set balance_weight '1:4'
state_set balance_winner ''
out="$(balance_status 2>/dev/null)"
echo "$out" | grep -q "按容量配比 1:4" \
    && ok "weighted 显示配比 1:4" || bad "weighted 没显示配比"
echo "$out" | grep -q "以太网 x1 / Wi-Fi x4" \
    && ok "配比拆解到两个接口" || bad "配比没拆解"
echo "$out" | grep -q "约每 10 分钟重测" \
    && ok "说明了配比会自动更新" || bad "没说配比会更新"
# 没有缓存配比时不能报错，要说明在等重测
state_del_balance_weight() { del_key balance_weight; }
del_key balance_weight
out="$(balance_status 2>/dev/null)"
echo "$out" | grep -q "等待守护进程重测后显示" \
    && ok "无缓存配比时说明在等待" || bad "无缓存配比时报了错或显示错"
# fastest 模式不能被显示成配比
state_set balance_mode fastest
out="$(balance_status 2>/dev/null)"
echo "$out" | grep -q "最快线路" && ok "fastest 仍显示最快线路" || bad "fastest 显示错"

echo "== 8. App 侧不能把 weighted 显示成轮询 =="
grep -q 'balanceStrategyLabel' SmartRouteApp/NetworkModel.swift \
    && ok "App 有策略显示名计算属性" || bad "App 缺策略显示名"
grep -q 'case "weighted":' SmartRouteApp/NetworkModel.swift \
    && ok "App 认 weighted 模式" || bad "App 不认 weighted"
grep -q '按容量配比' SmartRouteApp/NetworkModel.swift \
    && ok "App 显示配比" || bad "App 不显示配比"
grep -q 'out.contains("分流策略       : 按容量配比")' SmartRouteApp/NetworkModel.swift \
    && ok "App 解析 bash 输出的配比行" || bad "App 没解析配比行"
# 旧的二值判断必须去掉，否则 weighted 掉进 else 被显示成"轮询两条"
grep -q 'out.contains("分流策略       : 最快线路") { self.balanceMode = "fastest" }$' SmartRouteApp/NetworkModel.swift \
    && bad "还是二值判断，weighted 会被显示成轮询" || ok "没有残留的二值判断"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
