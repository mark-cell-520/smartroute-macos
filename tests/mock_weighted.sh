#!/bin/bash
# 加权分流：并发不该是 1:1 盲分，要按容量配比
#
# 为什么：本机是 100M 有线 + 432M Wi-Fi。1:1 轮询意味着每边只拿到一半连接，
# 而 Wi-Fi 明明还能多扛、100M 有线却已占满——总吞吐卡在慢的那条上，
# 用户体验就是"并发也没变快"。
#
# 做法：把快的网关在 pf route-to 列表里重复多次。pf 的 round-robin 只认
# 列表顺序、没有 weight 关键字，重复条目是唯一能近似配比的写法。
#
# 运行: bash tests/mock_weighted.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_wt.XXXXXX)"
mkdir -p "$T/bin" "$T/state" "$T/lock"
trap 'rm -rf "$T"' EXIT
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/pfctl"; chmod +x "$T/bin/pfctl"

# 生成规则并抓取 route-to 那一行。注意 PF_ANCHOR_FILE 必须在 source **之后**
# 赋值：脚本里有同名赋值，先 export 会被覆盖掉（这个坑本轮踩过一次）。
gen() {   # $1..$6 同 write_pf_rules
    bash -c ". '$T/sr.sh'; trap - EXIT INT TERM HUP
      export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
      export STATE_FILE='$T/state/st' LOCK_DIR='$T/lock'
      PF_ANCHOR_FILE='$T/rules.conf'
      write_pf_rules $1 $2 $3 $4 '' '' ${5:-1} ${6:-1} >/dev/null 2>&1
      grep -E '^# 策略|^pass out' '$T/rules.conf'" 2>/dev/null
}
# 数某个网关在 route-to 列表里出现几次
# 用 grep -o -F 固定字符串匹配：规则里是 "($ext1 $gw1)"，带 $ 符号。
# 不用 -F 时 $ 在正则里有特殊含义，且我最早把 $ 漏了、模式写成 "(ext1 gw1)"，
# 于是永远匹配 0 次——规则明明是对的，测试却全红。
count_gw() { echo "$1" | grep -o -F "($2 $3)" | wc -l | tr -d ' '; }

echo "== 1. 1:1 时退化为普通轮询 =="
R="$(gen en0 192.168.1.1 en1 192.168.2.1 1 1)"
echo "$R" | grep -q "round-robin" && ok "仍是 round-robin" || bad "丢了 round-robin"
[ "$(count_gw "$R" '$ext1' '$gw1')" = "1" ] && [ "$(count_gw "$R" '$ext2' '$gw2')" = "1" ] \
    && ok "两个网关各出现 1 次（1:1）" || bad "1:1 时配比不对: $R"

echo "== 2. 1:4 时慢的那条只出现 1 次 =="
R="$(gen en0 192.168.1.1 en1 192.168.2.1 1 4)"
[ "$(count_gw "$R" '$ext1' '$gw1')" = "1" ] && ok "以太网出现 1 次" || bad "以太网次数不对: $R"
[ "$(count_gw "$R" '$ext2' '$gw2')" = "4" ] && ok "Wi-Fi 出现 4 次" || bad "Wi-Fi 次数不对: $R"
echo "$R" | grep -q "weighted" \
    && ok "注释标明 weighted 1:4（用户能看懂为什么这样分）" || bad "缺 weighted 注释"

echo "== 3. 3:4 时两边都重复 =="
R="$(gen en0 192.168.1.1 en1 192.168.2.1 3 4)"
[ "$(count_gw "$R" '$ext1' '$gw1')" = "3" ] && ok "以太网出现 3 次" || bad "以太网次数不对: $R"
[ "$(count_gw "$R" '$ext2' '$gw2')" = "4" ] && ok "Wi-Fi 出现 4 次" || bad "Wi-Fi 次数不对: $R"

echo "== 4. 语法必须过真 pfctl =="
# 重复条目是不是合法语法，不能靠猜。这里用系统真 pfctl -n 解析
# （只需要读权限，不需要 sudo）。故意构造一个坏规则对照，
# 证明这个检查真的能抓到错误，不是永远返回 0。
bash -c ". '$T/sr.sh'; trap - EXIT INT TERM HUP
  export PATH='/usr/bin:/bin:/usr/sbin:/sbin' LOCK_DIR='$T/lock'
  PF_ANCHOR_FILE='$T/rules.conf'
  write_pf_rules en0 192.168.1.1 en1 192.168.2.1 '' '' 1 4 >/dev/null 2>&1"
_err="$(pfctl -n -f "$T/rules.conf" 2>&1 | grep -c 'syntax error')"
[ "${_err:-1}" = "0" ] && ok "加权规则通过 pfctl 解析（重复条目合法）" \
    || bad "加权规则有语法错误: $(pfctl -n -f "$T/rules.conf" 2>&1 | grep 'syntax error' | head -1)"
printf 'pass out route-to { ($ext1 $gw1) } round-robin BROKEN inet proto\n' > "$T/bad.conf"
_bad="$(pfctl -n -f "$T/bad.conf" 2>&1 | grep -c 'syntax error')"
[ "${_bad:-0}" != "0" ] && ok "对照组：坏规则确实会被 pfctl 抓到（检查不是假阳性）" \
    || bad "pfctl 抓不到坏语法，上面的通过不可信"

echo "== 5. 权重配比算法（用真实吞吐量代入）=="
# 快的一边定为 4，另一边按比例取整（至少 1）。不引入 gcd——
# 4 档已经够用，多一个 helper 不划算。
_w() {   # $1=t1 $2=t2 -> "w1 w2"
    if [ "$1" -ge "$2" ]; then w1=4; w2=$(( $2 * 4 / $1 )); [ "$w2" -lt 1 ] && w2=1
    else w2=4; w1=$(( $1 * 4 / $2 )); [ "$w1" -lt 1 ] && w1=1; fi
    echo "$w1 $w2"
}
[ "$(_w 100000000 432000000)" = "1 4" ] && ok "100M:432M -> 1:4（本机实况）" || bad "本机实况算错: $(_w 100000000 432000000)"
[ "$(_w 100000000 100000000)" = "4 4" ] && ok "等速 -> 4:4（等价 1:1）" || bad "等速算错: $(_w 100000000 100000000)"
[ "$(_w 200000000 250000000)" = "3 4" ] && ok "200M:250M -> 3:4" || bad "200:250 算错: $(_w 200000000 250000000)"
[ "$(_w 5000000 900000000)" = "1 4" ] && ok "极端差距也收敛到 1:4（不饿死慢的那条）" || bad "极端差距算错: $(_w 5000000 900000000)"

echo ""
echo "结果: $((PASS - FAIL)) 通过, $FAIL 失败"
