PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

#!/bin/bash
# 验证：探测目标去重 + route 输出被完全屏蔽
set -u
T=/tmp/sr_dedup
rm -rf "$T"; mkdir -p "$T/bin" "$T/state"
SRC="$(cd "$(dirname "$0")/.." && pwd)/smartroute.sh"

sed -e "\|^PATH=/usr/local/sbin:|d" "$SRC" \
  | awk '/^# ---------------- 入口 ----------------/{exit} {print}' > "$T/sr.sh"

# route mock：成功时往 stdout 打印（与真实 macOS 行为一致）
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
case "$1" in
  add) echo "add host $3: gateway $5" ;;
  delete) echo "delete host $3" ;;
  "-n") echo "    gateway: 192.168.1.1" ;;
esac
exit 0
EOF
cat > "$T/bin/ping" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/bin/id" <<'EOF'
#!/bin/bash
[ "$1" = "-u" ] && echo 0
exit 0
EOF
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH"
. "$T/sr.sh"
PROBE_TARGETS="223.5.5.5 119.29.29.29 114.114.114.114 1.1.1.1 8.8.8.8"
TLS_PROBE=1

out="$(probe_dev en1 192.168.1.1 | tr '\n' '|')"
echo "探测输出: [$out]"
# 新契约：第 1 行判定、第 2 行明细，共 2 行；route 的噪音一行都不能多
first="$(printf '%s' "$out" | cut -d'|' -f1)"
nlines="$(printf '%s' "$out" | tr -cd '|' | wc -c | tr -d ' ')"
if [ "$first" = "ok" ] && [ "$nlines" = "2" ]; then
    ok "输出干净（判定行 ok，共 2 行）"
else
    bad "输出被污染: [$out]"
fi

# 数一下 route add 被调用几次（应为 5 次：去重后）
cat > "$T/bin/route" <<'EOF'
#!/bin/bash
echo "route $*" >> /tmp/sr_dedup/calls.log
case "$1" in
  add) echo "add host $3: gateway $5" ;;
  "-n") echo "    gateway: 192.168.1.1" ;;
esac
exit 0
EOF
chmod +x "$T/bin/route"
: > "$T/calls.log"
probe_dev en1 192.168.1.1 >/dev/null 2>&1
n=$(grep -c "^route add" "$T/calls.log")
echo "route add 调用次数: $n"
if [ "$n" = "5" ]; then ok "目标已去重（5 个唯一目标）"; else bad "期望 5 次 route add，实际 $n 次"; fi
d=$(grep -c "^route delete" "$T/calls.log")
echo "route delete 调用次数: $d"
if [ "$d" -ge 5 ]; then ok "探测后清理了路由（$d 次 delete）"; else bad "清理不完整：只有 $d 次 delete"; fi

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]
