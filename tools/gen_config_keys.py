#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 smartroute.sh 生成 SmartRouteApp/GeneratedConfigKeys.swift。

为什么存在：App 的 sanitizeConf（配置导入校验）曾经在 Swift 里手写一份配置键
白名单，和 smartroute.sh 的 conf_value_ok 各成一套。已经实测漂移过四次：
BALANCE_MODE 漏 weighted、SPEED_TEST_URL 没限协议、WEIGHT_RECHECK 整个键
缺失、v2.3 的 LATENCY_AUTO 三键漏同步。每次漏同步的用户后果都一样：App 里
导入配置，那几行被静默判 rejected，界面显示"已导入"，守护进程重载后键没了。

生成式方案把唯一事实源收拢到 smartroute.sh：加配置键只改 bash 一处
（VALID_KEYS + conf_value_ok 的布尔/整数分支 + conf_value_hint），构建时
本文件自动重生，App 侧不可能再漂移。

用法：
    python3 tools/gen_config_keys.py          # 重新生成（build_app.sh 每次构建前自动跑）
    python3 tools/gen_config_keys.py --check  # 只比对不写回；不一致退出码 1
                                               # （tests/mock_conf_drift.sh 用）
"""
import io
import re
import sys
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'smartroute.sh'
OUT = ROOT / 'SmartRouteApp' / 'GeneratedConfigKeys.swift'

HEADER = '''// 本文件由 tools/gen_config_keys.py 自动生成，请勿手工修改。
//
// 唯一事实源是 smartroute.sh：VALID_KEYS 定义合法键全集，conf_value_ok 的
// 分支定义每个键的取值规则（0/1 布尔、非负整数、其它）。手写白名单的时代
// 这里和 bash 漂移过四次（BALANCE_MODE 漏 weighted、SPEED_TEST_URL 没限
// 协议、WEIGHT_RECHECK 缺失、LATENCY_AUTO 三键漏同步），用户后果都是
// "App 显示已导入、实际没生效"。现在加配置键只需改 smartroute.sh，然后：
//     python3 tools/gen_config_keys.py
// 重新生成；tests/mock_conf_drift.sh 会盯着本文件与 bash 源一致。

import Foundation

enum GeneratedConfigKeys {
    /// VALID_KEYS 全集：sanitizeConf 的导入白名单
    static let valid: Set<String> = [
%(valid)s
    ]

    /// conf_value_ok 里只收 0/1 的布尔键
    static let boolKeys: Set<String> = [
%(bool)s
    ]

    /// conf_value_ok 里必须是非负整数且有上界的键
    static let intKeys: Set<String> = [
%(int)s
    ]

    /// conf_value_ok 里整数键的统一上界（`[ "$val" -le N ]`）
    ///
    /// 为什么要把这个数字也生成过来：App 的 sanitizeConf 曾经只查"是不是非负
    /// 整数"，没查上界。于是 COOLDOWN=999999 这类值 App 放行、写进 userConf、
    /// 弹"已导入并生效"，而脚本解析层按上界把它丢掉、回落默认值——用户看到的
    /// 是 App 界面显示他导入的数，守护进程用的是默认值，且没人告诉他被丢了。
    /// 上界和键表是同一条规则的两半，只生成一半照样漂移。
    static let intBound: Int = %(bound)s
}
'''


def die(msg: str) -> NoReturn:
    sys.stderr.write('gen_config_keys: %s\n' % msg)
    sys.exit(1)


def swift_array(keys):
    return ',\n'.join('        "%s"' % k for k in keys)


def branch_keys(body, anchor, what):
    """从 conf_value_ok 函数体里抓一个 case 分支的键表。

    分支行形如：OK_N|FAIL_N|COOLDOWN|...|SPEED_SWITCH_RATIO)
    用 anchor 定位行首，防止抓到注释里提到的键名。
    """
    for line in body.split('\n'):
        s = line.strip()
        if s.startswith(anchor) and s.endswith(')'):
            return [k for k in s[:-1].split('|') if k]
    die('conf_value_ok 里找不到%s分支（锚点 %s）' % (what, anchor))


def branch_bound(body, anchor, what):
    """抓整数分支的 `[ "$val" -le N ]` 上界。

    找不到就die：宁可构建失败，也不要悄悄生成一个"没有上界"的键表——
    那等于把这条校验从 App 侧删掉，而复现的就是当初那个假导入 bug。
    """
    lines = body.split('\n')
    start = None
    for i, line in enumerate(lines):
        if line.strip().startswith(anchor):
            start = i
            break
    if start is None:
        die('conf_value_ok 里找不到%s分支（锚点 %s）' % (what, anchor))
    # 只在该分支内往后找（到下一个 case 标签为止），避免抓到别的分支的数字
    for line in lines[start + 1:]:
        s = line.strip()
        if s.endswith(')') and not s.startswith('#'):
            break
        m = re.search(r'"\$val"\s+-le\s+(\d+)', s)
        if m:
            return int(m.group(1))
    die('conf_value_ok 的%s分支里找不到 `[ "$val" -le N ]` 上界' % what)


def main():
    check_only = '--check' in sys.argv[1:]
    text = io.open(SRC, encoding='utf-8').read()

    m = re.search(r'^VALID_KEYS="([^"]+)"', text, re.M)
    if not m:
        die('smartroute.sh 里找不到 VALID_KEYS= 行')
    valid = m.group(1).split()

    fm = re.search(r'^conf_value_ok\(\) \{.*?^\}', text, re.M | re.S)
    if not fm:
        die('smartroute.sh 里找不到 conf_value_ok() 函数')
    body = fm.group(0)

    int_keys = branch_keys(body, 'OK_N|FAIL_N|', '整数')
    bool_keys = branch_keys(body, 'TLS_PROBE|NOTIFY|', '布尔')
    int_bound = branch_bound(body, 'OK_N|FAIL_N|', '整数')

    # ---- 自校验：生成器自己的输入一致性 ----
    dup = sorted(set(int_keys) & set(bool_keys))
    if dup:
        die('键同时出现在整数和布尔分支: %s' % dup)
    unknown = sorted((set(int_keys) | set(bool_keys)) - set(valid))
    if unknown:
        die('分支里的键不在 VALID_KEYS: %s' % unknown)
    dup_all = sorted({k for k in valid if valid.count(k) > 1})
    if dup_all:
        die('VALID_KEYS 有重复键: %s' % dup_all)
    if int_bound <= 0:
        die('整数上界不合理: %s' % int_bound)

    content = HEADER % {
        'valid': swift_array(sorted(valid)),
        'bool': swift_array(sorted(bool_keys)),
        'int': swift_array(sorted(int_keys)),
        'bound': int_bound,
    }

    if check_only:
        try:
            old = io.open(OUT, encoding='utf-8').read()
        except IOError:
            die('%s 不存在，先跑一次生成' % OUT)
        if old != content:
            die('%s 与 smartroute.sh 不同步——跑 python3 tools/gen_config_keys.py 重新生成'
                % OUT.name)
        print('gen_config_keys: %s 与 bash 源一致（%d 键）' % (OUT.name, len(valid)))
        return

    OUT.parent.mkdir(parents=True, exist_ok=True)
    io.open(OUT, 'w', encoding='utf-8').write(content)
    other = sorted(set(valid) - set(int_keys) - set(bool_keys))
    print('gen_config_keys: 已生成 %s（valid %d / bool %d / int %d；其余 %d 个键走'
          '字符串或枚举规则: %s）'
          % (OUT, len(valid), len(bool_keys), len(int_keys), len(other),
             ' '.join(other)))


if __name__ == '__main__':
    main()
