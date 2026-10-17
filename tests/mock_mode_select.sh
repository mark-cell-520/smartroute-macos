#!/bin/bash
# 行为测试：cmd_watch 的五种 MODE 选路分支 + 冷却期
#
# 背景：用户提的四项需求里，第 1 项（无网络自动切换 Wi-Fi/有线）和第 2 项
# （网速增加）都落在 cmd_watch 的 MODE 分支上。此前对这个分支只有
# mock_watch_integration.sh 的安全阀/pf 测试，**选路决策本身一次都没测过**：
# eth 挂了会不会切到 wifi、speed 模式会不会挑快的、latency 模式会不会挑
# 低延迟的、冷却期会不会拦住切换——全是空白。
#
# 这个测试用受控 mock 把 probe_dev 的返回值钉死，然后检查 cmd_watch 到底
# 把 want 算成了什么、有没有真的调 do_switch。
#
# 运行: bash tests/mock_mode_select.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

SRC="$(pwd)/smartroute.sh"
T="$(mktemp -d /tmp/sr_mode.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/log" "$T/run" "$T/etc"

: > "$T/calls.log"

# ── 外部命令替身 ──
# id 必须报 0：cmd_watch 里 apply_rules 只在 root 下跑，报 0 才会走到那步，
# 而我们要确认它没被真的执行（pfctl 不在 PATH 里，真跑会报错）。
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
chmod +x "$T/bin/"*

# 剥掉入口和硬编码 PATH，路径改到 /tmp
sed -e "s|^CONF=.*|CONF=\"$T/etc/smartroute.conf\"|" \
    -e "s|^USER_CONF=.*|USER_CONF=\"$T/etc/user.conf\"|" \
    -e "s|^RULES_FILE=.*|RULES_FILE=\"$T/etc/smartroute.rules\"|" \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"$T/state/state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/log/smartroute.log\"|" \
    -e "s|^LOCK_DIR=.*|LOCK_DIR=\"$T/run/lock\"|" \
    -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/pf.anchor\"|" \
    -e "s|^PF_STATE_FILE=.*|PF_STATE_FILE=\"$T/state/pf.state\"|" \
    -e "s|^SVC_ORDER_BAK=.*|SVC_ORDER_BAK=\"$T/state/svc_order_orig\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

# 跑一次 watch。环境变量控制探测结果：
#   ETH_RES / WIFI_RES   probe_dev 对两个接口的判定（ok|fail|na）
#   CUR_DEV              当前默认路由接口
#   MODE_V               选路模式
#   LAST_SWITCH          上次切换的时间戳（测冷却期）
#   ETH_SPD / WIFI_SPD   测得的吞吐（speed 模式用）
#   ETH_LAT / WIFI_LAT   测得的延迟（latency 模式用）
runwatch() {
    : > "$T/calls.log"
    bash -c "
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        . '$T/sr.sh'
        # ── 受控 mock：必须在 source 之后覆盖，否则被脚本里的定义盖掉 ──
        find_active() {
            ACTIVE_ETH_DEV='en0';  ACTIVE_ETH_SVC='Ethernet'
            ACTIVE_WIFI_DEV='en1'; ACTIVE_WIFI_SVC='Wi-Fi'
        }
        probe_dev() {   # \$1=dev \$2=gw；两行：判定 + 明细
            if [ \"\$1\" = 'en0' ]; then echo \"\${ETH_RES:-ok}\"; else echo \"\${WIFI_RES:-ok}\"; fi
            echo 'detail'
        }
        default_dev() { echo \"\${CUR_DEV:-en1}\"; }
        svc_router()  { [ \"\$1\" = 'Ethernet' ] && echo '192.168.1.1' || echo '192.168.1.1'; }
        do_switch()   { echo \"switch \$1\" >> '$T/calls.log'; }
        log()         { :; }
        notify()      { :; }
        apply_rules() { :; }
        wifi_failover_if_needed() { :; }
        ensure_throughput() { return 0; }
        ensure_latency()    { return 0; }
        _metric_val() {   # \$1=键名 → 查表
            case \"\$1\" in
                speed_en0) echo \"\${ETH_SPD:-0}\" ;;
                speed_en1) echo \"\${WIFI_SPD:-0}\" ;;
                lat_en0)   echo \"\${ETH_LAT:-0}\" ;;
                lat_en1)   echo \"\${WIFI_LAT:-0}\" ;;
            esac
        }
        _metric_fresh() { return 0; }
        MODE=\"\$MODE_V\"
        COOLDOWN=\"\${COOLDOWN_V:-45}\"
        [ -n \"\${LAST_SWITCH:-}\" ] && state_set last_switch \"\$LAST_SWITCH\"
        cmd_watch
    " 2>&1
}

# 从输出里取 want 字段。
# 注意 cmd_watch 打印的是 want=${want:-保持}，want 为空时输出字面量"保持"，
# 所以"保持"就是"没有切换意图"的规范表示，断言空值要认它。
want_of() { echo "$1" | sed -n 's/.*want=\([^ ]*\).*/\1/p'; }

# 预置连续失败计数。cmd_watch 用 update_streak 累计，FAIL_N=3 才算链路死亡，
# 而且当前链路有粘性（cur==该接口时一次失败也判 ok）。不预置的话单次失败
# 永远触发不了切换——那是滞回在起作用，不是 bug。
seed_streak() {   # $1=eth|wifi  $2=连续失败次数（正数）
    printf 'streak_%s=-%s\n' "$1" "$2" >> "$T/state/state"
}
# 同理，"可用"也要连续 ok 满 OK_N=2 才算。单次 ok 得 se=1 < 2，
# 且不在该线路上时判不可用——所以测"某条线是好的"必须预置 ok 计数。
seed_ok() {   # $1=eth|wifi  $2=连续成功次数
    printf 'streak_%s=%s\n' "$1" "$2" >> "$T/state/state"
}

echo "== 1. MODE=auto：无网络自动切换（需求 1）=="
# 先确认滞回：单次失败不该切换（FAIL_N=3 的意义就在这）
rm -f "$T/state/state"
o="$(ETH_RES=fail WIFI_RES=ok  CUR_DEV=en0 MODE_V=auto runwatch)"
grep -q "^switch" "$T/calls.log" && bad "单次失败就切换（滞回失效，会抖）" || ok "单次失败不切换（FAIL_N 滞回生效）"

# 连续失败满 3 次 → 切到 Wi-Fi
rm -f "$T/state/state"; seed_streak eth 3; seed_ok wifi 2
o="$(ETH_RES=fail WIFI_RES=ok  CUR_DEV=en0 MODE_V=auto runwatch)"
[ "$(want_of "$o")" = "en1" ] && ok "有线连续失败 → want=Wi-Fi" || bad "有线连续失败时 want=$(want_of "$o")，期望 en1"
grep -q "^switch en1$" "$T/calls.log" && ok "真的调了 do_switch en1" || bad "没有切换到 Wi-Fi"

# 反过来：Wi-Fi 连续失败、当前在 Wi-Fi → 切回有线
rm -f "$T/state/state"; seed_streak wifi 3; seed_ok eth 2
o="$(ETH_RES=ok  WIFI_RES=fail CUR_DEV=en1 MODE_V=auto runwatch)"
[ "$(want_of "$o")" = "en0" ] && ok "Wi-Fi 连续失败 → want=有线" || bad "Wi-Fi 连续失败时 want=$(want_of "$o")，期望 en0"

# 两边都好、当前在有线 → 保持（不无谓切换）
rm -f "$T/state/state"
o="$(ETH_RES=ok  WIFI_RES=ok  CUR_DEV=en0 MODE_V=auto runwatch)"
[ "$(want_of "$o")" = "en0" ] && ok "两边都好 → 保持当前线路" || bad "两边好时 want=$(want_of "$o")，应保持 en0"
grep -q "^switch" "$T/calls.log" && bad "两边都好却调了 do_switch（无谓切换）" || ok "两边好不切换"

# 两边都断 → 不能乱切
rm -f "$T/state/state"; seed_streak eth 3; seed_streak wifi 3
o="$(ETH_RES=fail WIFI_RES=fail CUR_DEV=en0 MODE_V=auto runwatch)"
[ "$(want_of "$o")" = "保持" ] && ok "两边都断 → 保持（不瞎切）" || bad "两边都断时 want=$(want_of "$o")，应为 保持"

echo "== 2. MODE=ethernet / wifi：强制走指定线路 =="
# 有线要连续 ok 满 OK_N=2 才算可用，预置上
rm -f "$T/state/state"; seed_ok eth 2
o="$(ETH_RES=ok WIFI_RES=ok CUR_DEV=en1 MODE_V=ethernet runwatch)"
[ "$(want_of "$o")" = "en0" ] && ok "ethernet 模式 → 拉回有线" || bad "ethernet 模式 want=$(want_of "$o")"
rm -f "$T/state/state"; seed_ok wifi 2
o="$(ETH_RES=ok WIFI_RES=ok CUR_DEV=en0 MODE_V=wifi runwatch)"
[ "$(want_of "$o")" = "en1" ] && ok "wifi 模式 → 拉到 Wi-Fi" || bad "wifi 模式 want=$(want_of "$o")"
# 指定的那条本身没网时不能硬切
rm -f "$T/state/state"; seed_streak eth 3
o="$(ETH_RES=fail WIFI_RES=ok CUR_DEV=en1 MODE_V=ethernet runwatch)"
[ "$(want_of "$o")" = "保持" ] && ok "ethernet 模式但有线没网 → 保持 Wi-Fi（不硬切）" || bad "有线没网却 want=$(want_of "$o")"

echo "== 3. MODE=speed：网速优先（需求 2）=="
# Wi-Fi 快 2 倍（超过 SPEED_SWITCH_RATIO=30%）→ 切 Wi-Fi
rm -f "$T/state/state"; seed_ok eth 2; seed_ok wifi 2
o="$(ETH_RES=ok WIFI_RES=ok CUR_DEV=en0 MODE_V=speed ETH_SPD=1000000 WIFI_SPD=3000000 runwatch)"
[ "$(want_of "$o")" = "en1" ] && ok "Wi-Fi 吞吐高 → 切 Wi-Fi" || bad "speed 模式 want=$(want_of "$o")，期望 en1"
# 反过来：有线快 → 切有线
rm -f "$T/state/state"; seed_ok eth 2; seed_ok wifi 2
o="$(ETH_RES=ok WIFI_RES=ok CUR_DEV=en1 MODE_V=speed ETH_SPD=3000000 WIFI_SPD=1000000 runwatch)"
[ "$(want_of "$o")" = "en0" ] && ok "有线吞吐高 → 切有线" || bad "speed 模式 want=$(want_of "$o")，期望 en0"
# 差距不够大（10% < 30%）→ 保持，别折腾
rm -f "$T/state/state"; seed_ok eth 2; seed_ok wifi 2
o="$(ETH_RES=ok WIFI_RES=ok CUR_DEV=en0 MODE_V=speed ETH_SPD=1000000 WIFI_SPD=1100000 runwatch)"
[ "$(want_of "$o")" = "en0" ] && ok "吞吐差距小 → 保持当前" || bad "差距小却切到了 $(want_of "$o")"
# 两边都测不出 → 不能瞎猜
o="$(ETH_RES=ok WIFI_RES=ok CUR_DEV=en0 MODE_V=speed ETH_SPD=0 WIFI_SPD=0 runwatch)"
[ "$(want_of "$o")" = "保持" ] && ok "都测不出 → 保持当前（不瞎猜）" || bad "都测不出时 want=$(want_of "$o")，应为 保持"

echo "== 4. MODE=latency：延迟优先 =="
# Wi-Fi 延迟低一半以上 → 切 Wi-Fi
rm -f "$T/state/state"; seed_ok eth 2; seed_ok wifi 2
o="$(ETH_RES=ok WIFI_RES=ok CUR_DEV=en0 MODE_V=latency ETH_LAT=30 WIFI_LAT=10 runwatch)"
[ "$(want_of "$o")" = "en1" ] && ok "Wi-Fi 延迟低 → 切 Wi-Fi" || bad "latency 模式 want=$(want_of "$o")，期望 en1"
# 差距小 → 保持
o="$(ETH_RES=ok WIFI_RES=ok CUR_DEV=en0 MODE_V=latency ETH_LAT=11 WIFI_LAT=10 runwatch)"
[ "$(want_of "$o")" = "en0" ] && ok "延迟差距小 → 保持当前" || bad "延迟差距小却切到 $(want_of "$o")"

echo "== 5. 冷却期：防止两条线之间反复横跳 =="
# last_switch 是 10 秒前，COOLDOWN=45 → 必须拦住
o="$(ETH_RES=fail WIFI_RES=ok CUR_DEV=en0 MODE_V=auto LAST_SWITCH=$(( $(date +%s) - 10 )) runwatch)"
[ "$(want_of "$o")" = "en1" ] && ok "冷却期内仍算出 want=Wi-Fi" || bad "want=$(want_of "$o")"
if grep -q "^switch" "$T/calls.log"; then bad "冷却期内居然切换了"; else ok "冷却期内拦住切换"; fi
# 超过冷却期 → 放行
o="$(ETH_RES=fail WIFI_RES=ok CUR_DEV=en0 MODE_V=auto LAST_SWITCH=$(( $(date +%s) - 100 )) runwatch)"
grep -q "^switch en1$" "$T/calls.log" && ok "冷却期过后放行切换" || bad "冷却期过了还不切换"

echo "== 6. do_switch 必须记录 last_switch（否则冷却期永远不生效）=="
# 这里不能 mock do_switch——要测的就是它本身。改用记录型替身只挡网络命令。
rm -f "$T/state/state"; seed_streak eth 3; seed_ok wifi 2
bash -c "
    export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
    . '$T/sr.sh'
    find_active() { ACTIVE_ETH_DEV='en0'; ACTIVE_ETH_SVC='Ethernet'; ACTIVE_WIFI_DEV='en1'; ACTIVE_WIFI_SVC='Wi-Fi'; }
    probe_dev() { if [ "\$1" = 'en0' ]; then echo 'fail'; else echo 'ok'; fi; echo d; }
    default_dev() { echo 'en0'; }
    svc_router() { echo '192.168.1.1'; }
    log() { :; }; notify() { :; }; apply_rules() { :; }
    wifi_failover_if_needed() { :; }
    # 只挡真正会改系统的动作，do_switch 保持真实
    reorder_first() { return 0; }
    route_add_default() { return 0; }
    route_delete_default() { return 0; }
    MODE='auto'
    cmd_watch
" >/dev/null 2>&1
_s="$(sed -n "s/^last_switch=//p" "$T/state/state" 2>/dev/null)"
[[ "$_s" =~ ^[0-9]+$ ]] && ok "切换后记录了 last_switch（${_s}）" || bad "没记录 last_switch（${_s:-空}）"

echo "== 7. 抖动计数不能被「本轮无需切换」清零（实测踩过）=="
# 真实症状：MODE=wifi 时 daemon 把默认路由切到 en1，下一轮 cur==want
# 走进清零分支；紧接着 macOS 又判回 en0，再下一轮 do_switch 把 flap_n
# 从 0 加到 1。于是 flap_count 永远在 0/1 之间振荡，永远到不了 3，
# 警报永远不响——switch_count 已 105 次而 flap_count 是空的。
# 用户完全不知道系统在反复改默认路由。
# 判据改成"距上次切换超过 1800s 才清零"，和 do_switch 的累加条件同尺度。
# 先删同键旧行再写入。用 >> 直接追会产生重复键，sed -n 'p' 于是输出
# 多行，"= 2" 这种字符串比较必然失败——看着像被测代码错了，其实是
# 夹具自己把状态文件写脏了。
seed_state() {
    local _k="${1%%=*}"
    if [ -f "$T/state/state" ]; then
        # grep -v 无行选中时返回 1（正是"该键本来不存在"），
        # 不能让它把 && 链短路，否则旧行删不掉、新行又追进去。
        local _t="$T/state/state.t" _rc=0
        grep -v "^$_k=" "$T/state/state" > "$_t" 2>/dev/null || _rc=$?
        [ "$_rc" -le 1 ] && mv "$_t" "$T/state/state" 2>/dev/null
        rm -f "$_t" 2>/dev/null
    fi
    printf '%s\n' "$1" >> "$T/state/state"
}
# 读单个键：只取第一行，防止夹具意外写出重复键时误判
sget() { sed -n "s/^$1=//p" "$T/state/state" 2>/dev/null | head -1; }

# 构造"刚抖过"的状态：last_switch 是 60 秒前，flap_count=2
now_s="$(date +%s)"
seed_state "last_switch=$((now_s-60))"
seed_state "flap_count=2"
seed_state "flap_target=en1"
out="$(MODE_V=wifi CUR_DEV=en1 runwatch 2>&1)"
[ "$(sget flap_count)" = "2" ] \
    && ok "刚抖过（60s 前）不清零，证据保留" || bad "刚抖过就被清零，警报永远不响"
echo "$out" | grep -q "默认路由已稳定" && bad "刚抖过却报'已稳定'" || ok "刚抖过不谎报稳定"

# 构造"真修好了"的状态：last_switch 是 1 小时前
seed_state "last_switch=$((now_s-3600))"
seed_state "flap_count=2"
out="$(MODE_V=wifi CUR_DEV=en1 runwatch 2>&1)"
[ "$(sget flap_count)" = "0" ] \
    && ok "1 小时没切换则清零（警报会自动消失）" || bad "真稳定了却不清零，警报永驻"
# 不查 log 输出：runwatch 把 log() mock 成 :，根本没有 stdout 可查
# （查了永远是失败，等于用夹具的限制惩罚被测代码）。改为代码级锁定
# 这行提示确实存在——用户需要知道警报为什么消失了。
grep -q 'log "默认路由已稳定，清除选路不稳定计数"' "$SRC" \
    && ok "真稳定时有 log 提示（代码级）" || bad "清零了却不告诉用户"

# 窗口内（1700s，离 1800 有足够余量，不受 seed→运行之间那几秒影响）
seed_state "last_switch=$((now_s-1700))"
seed_state "flap_count=2"
out="$(MODE_V=wifi CUR_DEV=en1 runwatch 2>&1)"
[ "$(sget flap_count)" = "2" ] \
    && ok "1700s 前刚抖过，计数保留" || bad "窗口内却被清零，会漏计"
echo "$out" | grep -q "默认路由已稳定" && bad "窗口内却报'已稳定'" || ok "窗口内不谎报稳定"

# 代码级锁定：清零用 -gt 1800，do_switch 累加用 -le 1800，两者必须互补。
# 不锁的话将来一边改成 1800/900，就会出现"累加了却立刻被清零"或
# "永远不清零"——而行为测试测不出这种数值漂移。
_sw="$(grep -n 'flap_gap.*-le 1800' "$SRC")"
_rs="$(grep -n '_last.*-gt 1800' "$SRC")"
[ -n "$_sw" ] && ok "do_switch 累加门槛是 -le 1800" || bad "do_switch 门槛被改了"
[ -n "$_rs" ] && ok "清零门槛是 -gt 1800（与累加互补）" || bad "清零门槛与累加不互补"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]
