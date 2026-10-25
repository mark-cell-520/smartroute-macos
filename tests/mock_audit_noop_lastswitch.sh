#!/bin/bash
# 回归测试：do_switch 的"无需调整"分支不许刷新 last_switch
#
# 曾经的病灶：do_switch 一进来就无条件 `state_set last_switch`，
# 而"无需调整"分支的注释写着"也不写 last_switch：没动过路由表"——
# 注释和代码相反，而且后果不止是说谎（见下）。
#
# 现在的代码：只在"确定要动路由表"的那一刻才记（兜底分支之前），
# 失败的尝试照样记（它确实动过路由表），无操作那条路不再续冷却期。
#
# 注释说不写，代码在 30 行前已经写完了。后果不是"状态难看"：last_switch 同时是
# **冷却期的时间基准**（1619-1625 行）和 **flap 计数 1800s staleness 窗口的基准**
# （1709-1714 行）。一次什么都没做的 do_switch 会把冷却期整个续掉。
#
# 失败场景：两条线都健康、Wi-Fi 更快（want=en1），服务顺序本来就是 Wi-Fi 优先。
# 某一轮探测期间 macOS 把默认路由判回了 en1（configd 重建默认路由），而 cmd_watch
# 在探测开始前采到的 cur 还是 en0 → do_switch 被调用 → 发现"默认路由已是 en1" →
# 什么都不做，却把 last_switch 刷新成现在。紧接着 macOS 又把它判回 en0：
# 下一轮 want=en1 仍然成立，但冷却期刚刚被这次"无操作"续满 45 秒 → 跳过切换。
# 用户多等最多 45 秒才回到快的那条线；如果 macOS 每隔 30 秒判回一次，
# 工具可能每次都刚好被自己刷新出来的冷却期挡掉。
#
# 运行: bash tests/mock_audit_noop_lastswitch.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

# 静态守卫读真实源文件（不是 sed 出来的副本）——要守的就是源文件本身
SRC="$(pwd)/smartroute.sh"

T="$(mktemp -d /tmp/sr_nl.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log" "$T/run" "$T/etc"

cat > "$T/bin/date" <<'EOF'
#!/bin/bash
[ "${1:-}" = "+%s" ] && { echo "${MOCK_NOW:-1700000000}"; exit 0; }
exec /bin/date "$@"
EOF
# 服务顺序：Wi-Fi 已经是第一个（无需重排）
cat > "$T/bin/networksetup" <<'EOF'
#!/bin/bash
case "$1" in
  -listnetworkserviceorder)
      printf '(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en1)\n\n(2) Ethernet\n(Hardware Port: Ethernet, Device: en0)\n' ;;
  -getinfo) printf 'Router: 192.168.1.1\n' ;;
esac
exit 0
EOF
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
case "$*" in
  *"get default"*) printf '  interface: en1\n' ;;
esac
exit 0
EOF
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
cat > "$T/bin/pfctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T/bin/"*

sed -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/l\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/l\"|" \
    -e "s|^SVC_ORDER_BAK=.*|SVC_ORDER_BAK=\"$T/state/svc\"|" \
    -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/anchor\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$(pwd)/smartroute.sh" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

run_case() {   # $1=cur（cmd_watch 采到的）  $2=do_switch 时 default_dev 返回什么
    : > "$T/state/state"; : > "$T/log/l"
    echo "last_switch=1699990000" > "$T/state/state"   # 1 小时前切过，冷却期早过了
    bash -c "
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export LOG_FILE='$T/log/l' STATE_FILE='$T/state/state' MOCK_NOW=1700000000
        . '$T/sr.sh'
        trap - EXIT INT TERM HUP
        export NOTIFY=0 BALANCE=0
        # 探测期间默认路由变成 en1（configd 重建），而 cmd_watch 采到的 cur 是 en0
        default_dev() { echo '$2'; }
        svc_of_dev() { [ \"\$1\" = en1 ] && echo 'Wi-Fi' || echo 'Ethernet'; }
        svc_router() { echo 192.168.1.1; }
        do_switch en1 '$1' ok ok 2 2
        echo \"last_switch=\$(state_get last_switch)\"
    " 2>&1
}

echo "== 1. 什么都不做的那一次，last_switch 被刷新了吗 =="
out="$(run_case en0 en1)"
printf '%s\n' "$out" | sed 's/^/    | /'
grep -q "默认路由已是 en1" "$T/log/l" \
    && ok "确实走了「无需调整」分支（没有动路由表、没有发通知）" || bad "没走到该分支: $(cat "$T/log/l")"
printf '%s\n' "$out" | grep -qx "last_switch=1700000000" \
    && bad "无操作也刷新了 last_switch——冷却期被一次什么都没做的调用续掉" \
    || ok "无操作不刷新 last_switch（冷却期不被续掉）"

echo
echo "== 2. 静态守卫：无条件写入不许回来 =="
# 行为测试只覆盖"无需调整"这一条路。这条 lint 覆盖全部无操作路径：
# do_switch 里 state_set last_switch 只许出现在"2) 兜底"附近，
# 不许出现在函数开头（那是当初病灶的位置）。
_DS="$(grep -n '^do_switch()' "$SRC" | head -1 | cut -d: -f1)"
[ -n "$_DS" ] && ok "找到 do_switch（第 ${_DS} 行）" || bad "找不到 do_switch"
# 判据：第一次写 last_switch 必须晚于第一次 reorder_first 调用。
# 为什么用 reorder_first 而不是"2) 兜底"注释当界桩：重排服务顺序本身就是
# 一个真实动作，那条路径上的写入是合法的（它确实动了系统配置）。
# 当初病灶的位置是**函数一进来就写**，早于任何动作——那才会让
# "无需调整"也续冷却期。界桩放在第一个动作上，两种错都能抓住。
_FIRST="$(awk -v s="$_DS" 'NR>s && /^[[:space:]]*state_set last_switch /{print NR; exit}' "$SRC")"
_ACT="$(awk -v s="$_DS" 'NR>s && /reorder_first /{print NR; exit}' "$SRC")"
echo "    第一次写 last_switch 在第 ${_FIRST:-?} 行，第一个动作（reorder_first）在第 ${_ACT:-?} 行"
if [ -n "$_FIRST" ] && [ -n "$_ACT" ] && [ "$_FIRST" -gt "$_ACT" ]; then
    ok "last_switch 只在确定要动手之后才写（无操作不续冷却期）"
else
    bad "do_switch 里出现了第一个动作之前的 last_switch 写入——无操作会续冷却期"
fi
# 每条成功/失败路径仍要记（原意图：失败的尝试也要节流）
_CNT="$(awk -v s="$_DS" 'NR>s && /^[[:space:]]*state_set last_switch /{c++} END{print c+0}' "$SRC")"
[ "${_CNT:-0}" -ge 2 ] \
    && ok "写点仍有 ${_CNT} 处（成功与失败路径都记，节流意图没丢）" \
    || bad "只剩 ${_CNT} 处写入——失败的尝试不再被节流，冷却期形同虚设"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]
