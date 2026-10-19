#!/bin/bash
# 用真实 pfctl -n 校验生成的 pf 规则语法（不需要 root）
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)/smartroute.sh"
T=/tmp/sr_pfreal
rm -rf "$T"; mkdir -p "$T/etc"
PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

sed -e "s|^PF_ANCHOR_FILE=.*|PF_ANCHOR_FILE=\"$T/etc/pf.anchor\"|" \
    -e "s|^PF_STATE_FILE=.*|PF_STATE_FILE=\"$T/etc/pf.state\"|" \
    -e "s|^LOG_FILE=.*|LOG_FILE=\"$T/etc/log\"|" \
    -e "\|^PATH=/usr/local/sbin:|d" \
    "$SRC" | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

. "$T/sr.sh"

check() {   # $1=说明 $2=设备A $3=设备B $4=排除 $5=只走的设备(fastest)
    write_pf_rules "$2" 192.168.1.1 "$3" 192.168.2.1 "$4" "${5:-}" >/dev/null 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then bad "$1（write_pf_rules 返回 ${rc}）"; return; fi
    if pfctl -n -f "$PF_ANCHOR_FILE" >/dev/null 2>&1; then
        ok "$1"
    else
        bad "$1 —— pfctl 报错："
        pfctl -n -f "$PF_ANCHOR_FILE" 2>&1 | grep -v "^pfctl: Use\|^present\|^See\|^$" | sed 's/^/       /'
    fi
}

echo "== 真实 pfctl -n 语法校验 =="
check "同网段（en0/en1 同在 192.168.1.0/24）" en0 en1 ""
check "不同网段（en0 / en5）"              en0 en5 ""
check "带 VPN 网段排除"                     en0 en1 "100.64.0.0/16 100.64.0.22/32"

check "fastest 只走 en0（同网段）" en0 en1 "" en0
check "fastest 只走 en1（同网段）" en0 en1 "" en1
check "fastest 只走 en0（不同网段）" en0 en5 "100.64.0.0/16" en0

echo "== 生成的规则内容（同网段）=="
write_pf_rules en0 192.168.1.1 en1 192.168.1.1 "" >/dev/null 2>&1
grep -v "^#" "$PF_ANCHOR_FILE" | sed 's/^/    /'

echo "== 锚点名可用性 =="
if pfctl -a com.apple/smartroute -n -f "$PF_ANCHOR_FILE" >/dev/null 2>&1; then
    ok "锚点 com.apple/smartroute 可加载（挂在系统 com.apple/* 通配锚点下）"
else
    bad "锚点加载失败"
fi

echo
echo "结果: $PASS 通过, $FAIL 失败"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
