#!/bin/bash
# 守护进程存活判断：pgrep 在这个 plist 下不可靠
#
# 这个 plist 用 StartInterval=20，进程只在每次运行的瞬间存在（约 1~2 秒），
# pgrep 命中率只有一成左右；而 launchctl print system/... 需要 root，
# App 的体检页是**不带 sudo** 调的。两条都不满足就报"未检测到"，
# 十次有八次误报，还劝用户重装一遍。
#
# 正确信号是日志新鲜度：cmd_watch 每轮结束往 stdout 打一行，
# plist 把它重定向到 /var/log/smartroute.out，mtime 就是心跳，
# 且普通用户就能 stat 到。
SRC="${SRC:-$(cd "$(dirname "$0")/.." && pwd)/smartroute.sh}"
checks=0; failures=0
ok()  { checks=$((checks+1)); printf '  ✓ %s\n' "$1"; }
bad() { failures=$((failures+1)); printf '  ✗ %s\n' "$1"; }

body="$(cat "$SRC")"
echo "== 1. 不能把 pgrep 当作唯一依据 =="
# 提取 doctor 里守护进程那一段
# 用 awk 提取：从 [7] 标记开始，到它后面第一个 esac 为止。
# 最早用 sed '/start/,/^    fi$/'，结果停在了内层那个 fi（90/300 秒分档的闭合），
# 把 pgrep / case 三态整段漏掉，7 条断言全假失败。
seg="$(printf '%s\n' "$body" | awk '/\[7\] smartroute 运行状态/{f=1} f{print} f&&/^    esac$/{exit}')"
[ -n "$seg" ] || bad "没提取到 [7] 段（提取规则失效，测试本身有问题）"
printf '%s' "$seg" | grep -q 'pgrep -f' && ok "仍用 pgrep，但已降级为佐证" || bad "pgrep 被完全移除（有 root 时它仍有价值）"
printf '%s' "$seg" | grep -q 'date +%s' && ok "用当前时间算心跳年龄" || bad "没有算心跳年龄"
printf '%s' "$seg" | grep -q 'stat -f%m /var/log/smartroute.out' \
    && ok "读 smartroute.out 的 mtime 作为心跳" || bad "没有读日志 mtime"
# launchctl print 必须只在有 root 时用
# id -u 和 launchctl print 分处两行（续行符 \），必须压平了再查，
# 否则 grep 单行匹配永远找不到，会误报"没做权限判断"。
printf '%s' "$seg" | tr '\n' ' ' | tr -s ' ' | grep -q 'id -u.*-eq 0.*launchctl print' \
    && ok "launchctl print 只在有 root 时兜底（否则必然失败）" || bad "launchctl print 没做权限判断"

echo "== 2. 三态：不能把「刚唤醒」说成「未检测到」=="
printf '%s' "$seg" | grep -q 'dage.*-lt 90' && ok "90 秒内算运行中" || bad "没有 90 秒档"
printf '%s' "$seg" | grep -q 'dage.*-lt 300' && ok "5 分钟内算等待中" || bad "没有等待档"
printf '%s' "$seg" | grep -q 'stopped)' && ok "超过 5 分钟才报未检测到" || bad "没有 stopped 档"
printf '%s' "$seg" | grep -q '等待下一次检测' \
    && ok "等待态说清是在等，不吓人" || bad "等待态没有单独文案"
printf '%s' "$seg" | grep -q '守护进程未运行：cd' \
    && ok "只有真停了才劝重装" || bad "重装建议没有限定在 stopped"

echo "== 3. 心跳年龄要显示出来 =="
# 显示"心跳 N 秒前"让人能自己判断，而不是只给一个结论
printf '%s' "$seg" | grep -q '心跳 ${dage} 秒前' \
    && ok "运行态显示心跳年龄" || bad "运行态没显示心跳年龄"
printf '%s' "$seg" | grep -q '上次心跳 ${dage} 秒前' \
    && ok "异常态也显示上次心跳时间" || bad "异常态没显示上次心跳"

echo "== 4. 选路模式要列全五个 =="
# 原来只写三个，用户选了"网速优先"后看体检报告会以为设置没生效
printf '%s\n' "$body" | grep -q 'auto=谁有外网走谁 / ethernet=强制有线 / wifi=强制无线 / speed=网速优先 / latency=延时优先' \
    && ok "五个模式都列了" || bad "模式说明不完整（漏了 speed/latency）"

echo "== 5. 心跳来源必须真实存在 =="
# 声称读 /var/log/smartroute.out 的 mtime，就得确认每轮真的往那写
printf '%s\n' "$body" | grep -q 'echo "$(ts) eth=' \
    && ok "cmd_watch 每轮往 stdout 打一行（plist 重定向进 smartroute.out）" \
    || bad "cmd_watch 不往 stdout 写，mtime 不会更新，心跳判断失效"
# plist 里必须真的配了 StandardOutPath
plist="${PLIST:-$(cd "$(dirname "$0")/.." && pwd)/com.user.smartroute.plist}"
grep -q '/var/log/smartroute.out' "$plist" && ok "plist 配了 StandardOutPath" || bad "plist 没重定向 stdout"

echo ""
echo "结果: $((checks - failures)) 通过, $failures 失败"
