import Foundation

// 纯格式化函数。放在独立文件而不是 Views.swift，是因为 tests/mock_swift_parse.sh
// 的构建 glob 排除了 Views.swift（它只含 View，会拖进一堆 UI 依赖）。
// 纯逻辑放在测不到的文件里，就等于没有测试——只能靠复刻版覆盖，
// 而复刻版验证不了"Swift 里的实现就是这个算法"。
//
// 新增纯函数请放这里，不要放 Views.swift。

/// 把探测连续计数格式成人话。
///
/// 脚本侧的取值约定（smartroute.sh 的 state_get / update_streak）：
///   · 正数  = 连续成功次数
///   · "-N"  = 连续失败次数
///   · "0"   = 判定尚未确立（探测被中断/结果异常/接口未激活）
///   · "-"   = state_get 取不到这个键
///   · ""    = 同上
///
/// 后两种都是"不知道"，必须显示"未知"。
/// 以前只处理了 "0" 和 ""，"-" 被 dropFirst() 拿到空串，
/// 渲染成"连续失败  次"——一个中间空两格的标签，
/// 出现在默认落地页的接口卡片上。用户看到只会困惑。
func streakText(_ streak: String) -> String {
    if streak == "0" || streak.isEmpty { return "未知" }
    if streak.hasPrefix("-") {
        let n = String(streak.dropFirst())
        // "-" 取不到键时的占位，不是"连续失败 0 次"
        if n.isEmpty { return "未知" }
        return "连续失败 \(n) 次"
    }
    return "连续成功 \(streak) 次"
}
