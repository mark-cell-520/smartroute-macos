// 本文件由 tools/gen_config_keys.py 自动生成，请勿手工修改。
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
        "AUTO_WIFI_POWER",
        "BALANCE",
        "BALANCE_MODE",
        "COOLDOWN",
        "FAIL_N",
        "FASTEST_RECHECK",
        "FASTEST_SWITCH_RATIO",
        "LATENCY_AUTO",
        "LATENCY_AUTO_GAP_MS",
        "LATENCY_AUTO_RATIO",
        "LATENCY_RECHECK",
        "MODE",
        "NC_TIMEOUT",
        "NOTIFY",
        "OK_N",
        "PING_TIMEOUT",
        "PROBE_TARGETS",
        "SPEED_RECHECK",
        "SPEED_SWITCH_RATIO",
        "SPEED_TEST_TIMEOUT",
        "SPEED_TEST_URL",
        "SPEED_TEST_URLS",
        "TLS_PROBE",
        "WEIGHT_RECHECK",
        "WIFI_FAILOVER",
        "WIFI_FAILOVER_COOLDOWN",
        "WIFI_PREFERRED"
    ]

    /// conf_value_ok 里只收 0/1 的布尔键
    static let boolKeys: Set<String> = [
        "AUTO_WIFI_POWER",
        "BALANCE",
        "LATENCY_AUTO",
        "NOTIFY",
        "TLS_PROBE",
        "WIFI_FAILOVER"
    ]

    /// conf_value_ok 里必须是非负整数且有上界的键
    static let intKeys: Set<String> = [
        "COOLDOWN",
        "FAIL_N",
        "FASTEST_RECHECK",
        "FASTEST_SWITCH_RATIO",
        "LATENCY_AUTO_GAP_MS",
        "LATENCY_AUTO_RATIO",
        "LATENCY_RECHECK",
        "NC_TIMEOUT",
        "OK_N",
        "PING_TIMEOUT",
        "SPEED_RECHECK",
        "SPEED_SWITCH_RATIO",
        "SPEED_TEST_TIMEOUT",
        "WIFI_FAILOVER_COOLDOWN"
    ]

    /// conf_value_ok 里整数键的统一上界（`[ "$val" -le N ]`）
    ///
    /// 为什么要把这个数字也生成过来：App 的 sanitizeConf 曾经只查"是不是非负
    /// 整数"，没查上界。于是 COOLDOWN=999999 这类值 App 放行、写进 userConf、
    /// 弹"已导入并生效"，而脚本解析层按上界把它丢掉、回落默认值——用户看到的
    /// 是 App 界面显示他导入的数，守护进程用的是默认值，且没人告诉他被丢了。
    /// 上界和键表是同一条规则的两半，只生成一半照样漂移。
    static let intBound: Int = 86400
}
