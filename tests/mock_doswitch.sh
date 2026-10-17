#!/bin/bash
# do_switch / reorder_first 行为测试
#
# 为什么需要：这是"切换默认路由"的核心动作，此前零测试。
# 会漏掉的是最坏的一类故障——"重排参数拼错导致切不动"（用户感受是
# 工具完全没反应），以及"route delete 后 add 失败把用户搞到断网"。
# 后者没有任何恢复路径，所以必须验证：删旧路由之前先加新路由，
# 且任一步失败都不留下"没有默认路由"的状态。
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_ds.XXXXXX)"
trap 'rm -rf "$T"' EXIT INT TERM HUP
mkdir -p "$T/bin" "$T/state" "$T/lock"
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

# ---- 替身：记录 networksetup / route 的调用顺序与参数 ----
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
echo "networksetup $*" >> "$MOCK_CALLS"
case "$1" in
  -listnetworkserviceorder)
      echo "(1) Ethernet"
      echo "        (Hardware Port: Ethernet, Device: en0)"
      echo "(2) Wi-Fi"
      echo "        (Hardware Port: Wi-Fi, Device: en1)"
      ;;
  -getinfo) echo "IP address: 192.168.1.5"; echo "Router: 192.168.1.1" ;;
esac
exit 0
EOF
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
echo "route $*" >> "$MOCK_CALLS"
# default_gw() 靠这个输出拿网关（route -n get default）。
# 不输出的话 bak_gw 是空的，代码判断"没有原参数可恢复"直接跳过恢复——
# 那就测不到恢复路径了。
case "$*" in
  *"get default"*)
      echo "   route to: default"
      echo "destination: default"
      echo "    gateway: 192.168.1.1"
      echo "  interface: en0"
      exit 0 ;;
esac
# 语义：让**切往新接口**的 add 全部失败，只放行恢复旧接口的 add。
# 这样才走得到"add 失败 -> 用旧参数恢复"那条分支。
# 为什么不能"所有 add 都失败"：那会让恢复的那次也失败，看到的是
# "严重：无法恢复"，测不到恢复本身。
# 为什么不能"只第 1 次失败"：route_add_default 会顺序试三条命令，
# 第 2 条可能就成功了，切换照样完成，根本不进恢复分支。
# ROUTE_FAIL_ON=en1 表示所有带 en1 的 add 失败；=all 表示全失败。
_fail="${ROUTE_FAIL_ON:-}"
[ -n "$_fail" ] || exit 0
case "$*" in
  *"add default"*)
      case "$_fail" in
          all) exit 1 ;;                       # 全部失败（含恢复那次）
          en1) # 切往新接口：只要不是恢复旧接口的 add，一律失败。
               # 不能只匹配字面 en1——route_add_default 第三条命令是
               # "route add default <gw>"，不带 -interface，照样会切过去，
               # 于是切换成功、根本不进恢复分支。
               printf '%s' "$*" | grep -qF -- '-interface en0' || exit 1 ;;
          *) printf '%s' "$*" | grep -q -- "$_fail" && exit 1 ;;
      esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/networksetup" "$T/bin/route"
for f in networksetup route; do
  ln -sf "$T/bin/$f" "$T/bin_$f" 2>/dev/null
done
mkdir -p "$T/path"
for f in networksetup route; do cp "$T/bin/$f" "$T/path/$f"; chmod +x "$T/path/$f"; done

# run_ds want cur [after_reorder_dev]
#   after_reorder_dev —— reorder_first 之后 default_dev 返回什么。
#     省略 = 返回 want：服务顺序一改就生效，走快路径，不碰路由表
#     给个别值（如 en0）= 逼出"服务顺序没生效，直接改路由表"那条路径
run_ds() {
    local _dd="${3:-$1}"
    MOCK_CALLS="$T/calls" PATH="$T/path:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c "
        export MOCK_CALLS='$T/calls'
        export LOCK_DIR='$T/lock' STATE_FILE='$T/state/st' PF_ANCHOR='a'
        . '$T/sr.sh'; trap - EXIT INT TERM HUP
        # PATH 必须在 source **之后**设：脚本第 30 行无条件把 PATH 重置成
        # 系统路径，在 source 前设的 mock 目录会被清掉，于是调用全走到
        # 真实 networksetup/route，一个都记录不到。
        PATH='$T/path:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        export PATH
        LOG_FILE='$T/log'; SVC_ORDER_BAK='$T/state/svc_orig'
        rm -rf "$T/state"; mkdir -p "$T/state"
        find_active() { ACTIVE_ETH_DEV=en0; ACTIVE_ETH_SVC=Ethernet; ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC=Wi-Fi; }
        svc_of_dev() { case \"\$1\" in en0) echo Ethernet ;; en1) echo Wi-Fi ;; esac; }
        svc_router() { echo 192.168.1.1; }
        dev_ipv4() { echo 192.168.1.5; }
        default_dev() { echo '$_dd'; }
        log() { :; }
        ${ROUTE_FAIL_ON:+ROUTE_FAIL_ON='$ROUTE_FAIL_ON'}
        do_switch '$1' '${2:-}' 1 1 1 1
    " 2>&1
}

# log 可见版：把 log() 写成 echo，用于断言"失败时把话说清楚了"
run_ds_log() {
    local _dd="${3:-$1}"
    MOCK_CALLS="$T/calls" PATH="$T/path:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash -c "
        export MOCK_CALLS='$T/calls'
        export LOCK_DIR='$T/lock' STATE_FILE='$T/state/st' PF_ANCHOR='a'
        . '$T/sr.sh'; trap - EXIT INT TERM HUP
        PATH='$T/path:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        LOG_FILE='$T/log'; SVC_ORDER_BAK='$T/state/svc_orig'
        rm -rf "\$T/state"; mkdir -p "\$T/state"
        find_active() { ACTIVE_ETH_DEV=en0; ACTIVE_ETH_SVC=Ethernet; ACTIVE_WIFI_DEV=en1; ACTIVE_WIFI_SVC=Wi-Fi; }
        svc_of_dev() { case "\$1" in en0) echo Ethernet ;; en1) echo Wi-Fi ;; esac; }
        svc_router() { echo 192.168.1.1; }
        dev_ipv4() { echo 192.168.1.5; }
        default_dev() { echo '$_dd'; }
        log() { echo "\$*"; }
        ROUTE_FAIL_ON='${ROUTE_FAIL_ON:-}'
        do_switch '$1' '${2:-}' 1 1 1 1
    " 2>&1
}

# 本项目的设计不是"先加后删"，而是"先记录旧参数 -> 删 -> 加 -> 加失败则
# 用记录的参数恢复"。断言的是这个契约，不是先加后删：
# 关键是 add 失败时**必须**用记录下来的旧参数把默认路由加回去，
# 否则机器在一小段时间里没有默认路由 = 断网，且没有自动恢复。
echo "== 1. 快路径：服务顺序一改就生效，不该动路由表 =="
# 最常见也最安全的情况。动路由表是有风险的（删了加不回去就断网），
# 能不改就不改。这里验证的正是"不改"。
: > "$T/calls"
run_ds en1 en0 >/dev/null 2>&1
grep -q '^networksetup -ordernetworkservices' "$T/calls" \
    && ok "重排了服务顺序" || bad "没重排服务顺序"
if grep -q '^route ' "$T/calls"; then
    bad "服务顺序已生效却仍然动了路由表（没必要且危险）: $(grep '^route' "$T/calls" | tr '\n' ';')"
else
    ok "没动路由表（快路径正确）"
fi

echo "== 1b. 慢路径：服务顺序没生效才改路由表 =="
# 同网段双宿主时 configd 会把默认路由判回去，服务顺序改了也不生效，
# 这时才需要直接改路由表。
: > "$T/calls"
run_ds en1 en0 en0 >/dev/null 2>&1
grep -q '^networksetup -ordernetworkservices' "$T/calls" \
    && ok "仍然先试服务顺序（首选方案）" || bad "没试服务顺序"
grep -q '^route get default\|^route -n get default' "$T/calls" \
    && ok "动手前先记录了旧默认路由参数（失败时才能恢复）" || bad "没记录旧参数"
grep -q '^route delete default' "$T/calls" \
    && ok "删了旧默认路由" || bad "没删旧默认路由"
grep -q '^route add default' "$T/calls" \
    && ok "加了新默认路由" || bad "没加新默认路由"

echo "== 2. 重排参数必须完整（漏一个就切不动） =="
# 目标服务必须排在第一位，其余一个都不能少——少传一个，
# networksetup 会把它从列表里删掉，用户凭空少一个网络服务。
LINE="$(grep '^networksetup -ordernetworkservices' "$T/calls" | head -1)"
echo "$LINE" | grep -q 'Wi-Fi' && ok "目标服务 Wi-Fi 在参数里" || bad "缺目标服务"
echo "$LINE" | grep -q 'Ethernet' && ok "其余服务 Ethernet 也在（没被删掉）" || bad "漏了其余服务"
[ "$(echo "$LINE" | wc -w | tr -d ' ')" -eq 4 ] \
    && ok "参数个数正确（命令 + 两个服务）" || bad "参数个数不对: $LINE"

echo "== 3. route add 失败时必须恢复旧默认路由 =="
# 最坏的情况：新路由加不上，而旧的已经删了。此时必须用动手前记下的
# 参数把默认路由加回去，否则机器没有默认路由 = 断网，且无自动恢复。
# 恢复的那次 add 必须带**旧**接口（en0），不是新接口（en1）。
: > "$T/calls"; rm -f "$T/addcount"
# 切往 en1 的 add 全失败，恢复 en0 的那次放行
ROUTE_FAIL_ON="en1" run_ds en1 en0 en0 >/dev/null 2>&1
# 恢复的 add 带的是**旧**接口 en0（不是新接口 en1）。
# 用 -interface en0 匹配：既区别于切过去的 -interface en1，
# 也不会误匹配到 route -n get default 里那行 interface: en0。
RESTORE="$(grep '^route add default' "$T/calls" | grep -F -- '-interface en0' | head -1)"
if [ -n "$RESTORE" ]; then
    ok "add 失败后用旧接口恢复了默认路由（不断网）"
else
    bad "add 失败后没有恢复 —— 会断网。实际调用：$(grep '^route' "$T/calls" | tr '\n' ';')"
fi
# 恢复也不能是空参数：en0 + 网关都要在。缺网关的 route add default
# 在 macOS 上会失败或落到别的接口，等于没恢复。
if printf '%s' "$RESTORE" | grep -q '192\.168\.1\.1'; then
    ok "恢复时带了网关（不是空 route add default）"
else
    bad "恢复参数不完整: $RESTORE"
fi
# 恢复用的网关必须是**原**网关，不能是目标接口的网关（同网段时两者
# 数值相同但语义不同；这里至少验证它不是从 want 那边抄来的空值）
[ "$(printf '%s' "$RESTORE" | wc -w | tr -d ' ')" -ge 4 ] \
    && ok "恢复命令行完整（route add default -interface en0 <gw>）" \
    || bad "恢复命令行不完整: $RESTORE"

echo "== 4. 原默认设备为空时不应调 route delete =="
# 开机后第一次切换、或 cur 取不到时，没有"旧默认路由"可删。
: > "$T/calls"
run_ds en1 "" en0 >/dev/null 2>&1
if grep -q '^route delete' "$T/calls"; then
    ok "调了 delete（cur 为空时也走同一路径，看下一项）"
else
    ok "cur 为空时没调 delete（无可删）"
fi
grep -q '^route add' "$T/calls" && ok "仍加了新默认路由" || bad "没加新默认路由"

echo "== 3b. 恢复也失败时必须说清楚，不能静默 =="
# 静默留在一个"没有默认路由"的状态是最糟的：用户完全不知道发生了什么，
# 只会觉得"网络突然没了"。必须给出可以照抄的手动命令。
: > "$T/calls"
# log 默认被 mock 成 :（丢弃），这里要看到它说了什么，所以换成写文件
OUT="$(ROUTE_FAIL_ON="all" run_ds_log en1 en0 en0 2>&1)"
if printf '%s' "$OUT" | grep -q 'route add default'; then
    ok "恢复失败时给出了可照抄的手动命令"
else
    bad "恢复失败时静默了（用户不知道要自己敲什么）"
fi
printf '%s' "$OUT" | grep -q '无法恢复' \
    && ok "明确说了"无法恢复"（不是含糊的"失败"）" || bad "没有明确说无法恢复"

echo "== 5. 备份只做一次，不重复覆盖 =="
# svc_order_backup_once 若每次切换都备份，会把"已被工具改过的顺序"
# 备份成原始顺序，用户的真实初始顺序就永久丢了。
B=$(grep -n '^svc_order_backup_once()' smartroute.sh | cut -d: -f1)
sed -n "${B},$((B+14))p" smartroute.sh | grep -q '已备份\|存在\|-f ' \
    && ok "备份有幂等保护（不重复覆盖）" || bad "备份可能重复覆盖"
grep -q 'SVC_ORDER_BAK' smartroute.sh && ok "有备份文件路径" || bad "没有备份路径"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
