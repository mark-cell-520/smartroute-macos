#!/bin/bash
# 测试 VPN 护栏：vpn_holds_default / vpn_full_tunnel / other_nets
#
# 为什么必须测：这三道护栏是"会不会把用户的 VPN 流量漏出去"的唯一防线。
# balance on 前会调用它们，失效的后果不是报错难看，而是**用户以为流量走了 VPN，
# 实际被分流漏到别的接口上**——对用 VPN 办公的人来说这是安全问题。
# 而它们此前零测试（审计意见原话："开启路径上的 VPN 保护零测试"）。
#
# 运行: bash tests/mock_vpn_guard.sh
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  OK %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  XX %s\n' "$1"; }

T="$(mktemp -d /tmp/sr_vpn.XXXXXX)"
mkdir -p "$T/bin"
trap 'rm -rf "$T"' EXIT
awk '/^# ---------------- 入口 ----------------/{exit} {print}' smartroute.sh > "$T/sr.sh"

# ---------- mock ----------
# netstat -rn -f inet 的输出由文件提供，route -n get default 同理
cat > "$T/bin/netstat" <<'EOF'
#!/bin/bash
cat "$MOCK_ROUTES" 2>/dev/null
exit 0
EOF
chmod +x "$T/bin/netstat"

cat > "$T/bin/route" <<'EOF'
#!/bin/bash
[ -f "$MOCK_DEFAULT" ] && cat "$MOCK_DEFAULT"
exit 0
EOF
chmod +x "$T/bin/route"

run_in() {
    bash -c "
        . '$T/sr.sh'
        trap - EXIT INT TERM HUP
        export PATH='$T/bin:/usr/bin:/bin:/usr/sbin:/sbin'
        export MOCK_ROUTES='$1' MOCK_DEFAULT='$2'
        export LOG_FILE='$T/sr.log'
        $3
    " 2>&1
}

# 普通双网卡路由表：默认走 en1，另有以太网子网和 VPN 的办公网段
cat > "$T/r_normal" <<'EOF'
default            192.168.1.1        UGSc           en1
default            10.8.0.1            UGSc        utun4
10.8.0.0/24        10.8.0.1            UGSc        utun4
192.168.1/24       link#4              UCS           en0
192.168.1.1/32     link#4              UCS           en0
EOF
printf '  interface: en1\n' > "$T/d_en1"
printf '  interface: utun4\n' > "$T/d_utun"
# 全流量 VPN：0/1 + 128/1 两条合起来覆盖整个 IPv4 空间
cat > "$T/r_full" <<'EOF'
default            10.8.0.1            UGSc        utun4
0/1                10.8.0.1            UGSc        utun4
128/1              10.8.0.1            UGSc        utun4
192.168.1/24       link#4              UCS           en0
EOF
# 只有 0/1 一半（不是全流量）
cat > "$T/r_half" <<'EOF'
default            192.168.1.1        UGSc           en1
0/1                10.8.0.1            UGSc        utun4
EOF
# 完全没有 VPN
cat > "$T/r_novpn" <<'EOF'
default            192.168.1.1        UGSc           en1
192.168.1/24       link#4              UCS           en0
EOF

echo "== 1. vpn_holds_default：默认路由归谁 =="
run_in "$T/r_normal" "$T/d_en1" 'vpn_holds_default && echo YES || echo NO' | grep -qx NO \
    && ok "默认走 en1 时不认为 VPN 持有" || bad "默认走 en1 却报 VPN 持有"
run_in "$T/r_normal" "$T/d_utun" 'vpn_holds_default && echo YES || echo NO' | grep -qx YES \
    && ok "默认走 utun4 时识别为 VPN 持有" || bad "默认走 utun4 却没识别"
# 各种 VPN 类接口名都要认
for dev in utun0 ppp0 ipsec0 tun0 tap0; do
    printf '  interface: %s\n' "$dev" > "$T/d_x"
    r="$(run_in "$T/r_novpn" "$T/d_x" 'vpn_holds_default && echo YES || echo NO')"
    printf '%s' "$r" | grep -qx YES && ok "识别 $dev 为 VPN 接口" || bad "$dev 没被识别"
done
# 普通网卡不能误判
for dev in en0 en1 en5 bridge0; do
    printf '  interface: %s\n' "$dev" > "$T/d_x"
    r="$(run_in "$T/r_novpn" "$T/d_x" 'vpn_holds_default && echo YES || echo NO')"
    printf '%s' "$r" | grep -qx NO && ok "$dev 不误判为 VPN" || bad "$dev 被误判成 VPN"
done

echo "== 2. vpn_full_tunnel：全流量 VPN 检测 =="
run_in "$T/r_full" "$T/d_utun" 'vpn_full_tunnel && echo YES || echo NO' | grep -qx YES \
    && ok "0/1 + 128/1 识别为全流量 VPN" || bad "0/1+128/1 没识别出来"
# 注意：这里用的是一张**真正的 split-tunnel** 路由表——只有办公网段，
# 没有第二条 default。最早我的样例里写了 "default ... utun4"，
# 那不是 split-tunnel（VPN 持有 default 路由时 vpn_holds_default 已经会拦），
# 断言本身就写错了。
cat > "$T/r_split" <<'EOF'
default            192.168.1.1        UGSc           en1
10.8.0.0/24        10.8.0.1            UGSc        utun4
192.168.1/24       link#4              UCS           en0
EOF
run_in "$T/r_split" "$T/d_en1" 'vpn_full_tunnel && echo YES || echo NO' | grep -qx NO \
    && ok "split-tunnel（只有办公网段）不算全流量，可正常并发" || bad "把 split-tunnel 误判成全流量（会拒绝正常使用）"
# 保守行为：只要 VPN 接口上存在 default 路由，即使物理接口也有一条 default，
# 也算全流量。这个方向是安全的——宁可拒绝分流，也不漏流量。
run_in "$T/r_normal" "$T/d_en1" 'vpn_full_tunnel && echo YES || echo NO' | grep -qx YES \
    && ok "VPN 接口上有 default 路由时按全流量处理（保守，安全方向）" || bad "VPN default 路由没被发现"
run_in "$T/r_novpn" "$T/d_en1" 'vpn_full_tunnel && echo YES || echo NO' | grep -qx NO \
    && ok "没有 VPN 时不算全流量" || bad "没有 VPN 却报全流量"

echo "== 3. other_nets：要排除的 VPN 网段 =="
out="$(run_in "$T/r_normal" "$T/d_en1" 'other_nets')"
printf '%s' "$out" | grep -qx "10.8.0.0/24" \
    && ok "提取出 VPN 网段 10.8.0.0/24" || bad "没提取到 10.8.0.0/24: $(printf '%s' "$out" | tr '\n' ' ')"
# 物理接口的网段不能被当成 VPN 网段排除掉
printf '%s' "$out" | grep -q "192.168.1" \
    && bad "把物理网段也排除了（会把自己关在外面）" || ok "不排除物理网段"

echo "== 4. 无 VPN 时 other_nets 应为空 =="
out="$(run_in "$T/r_novpn" "$T/d_en1" 'other_nets')"
[ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] \
    && ok "无 VPN 时输出为空" || bad "无 VPN 时却输出了: $(printf '%s' "$out" | tr '\n' ' ')"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]
