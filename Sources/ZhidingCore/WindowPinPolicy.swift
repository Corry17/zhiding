import Foundation

/// 原窗口置顶的能力边界；授权状态不能替代平台能力判断。

public enum WindowPinPolicy {
    public static let isSupported = false
    public static let title = "原窗口置顶暂不可用"
    public static let explanation = "旧实现误把 AXSubrole 当成窗口层级开关。Apple SDK 将它定义为只读的辅助功能类型描述，不能用来把其他应用的窗口设为永久置顶。当前实现已停用，不需要继续申请或重置辅助功能权限。"
    public static let alternative = "窗口镜像可以置顶查看，但不能在镜像里点击、滚动或输入。要操作原窗口，请切回原应用；若原应用自带“始终置顶”，可使用它自己的功能。"
    public static let sandboxExplanation = "当前应用保留 App Sandbox。辅助功能跨应用控制另受沙盒限制；授予辅助功能权限不等于解除沙盒限制。"

}
