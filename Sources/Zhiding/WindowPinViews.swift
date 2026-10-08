import SwiftUI
import AppKit
import ZhidingCore

/// 说明不可用的真实原因；不枚举窗口、不引导无效授权、不自动改为镜像。
struct WindowPinUnavailableView: View {
    let onMirror: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(WindowPinPolicy.title, systemImage: "info.circle").font(.title3.bold())
            Text(WindowPinPolicy.explanation)
            Text(WindowPinPolicy.sandboxExplanation).foregroundStyle(.secondary)
            Divider()
            Text(WindowPinPolicy.alternative)
            #if DEBUG
            Button("选择窗口镜像（仅查看）", action: onMirror).buttonStyle(.bordered)
            #else
            Text("Release 构建的镜像也尚未开放，请勿将此开发版对外分发。")
                .foregroundStyle(.secondary)
            #endif
        }.font(.callout).padding(24).frame(minWidth: 560, minHeight: 380)
    }
}
