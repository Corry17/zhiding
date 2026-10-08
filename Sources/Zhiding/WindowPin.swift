import AppKit
import SwiftUI
import ZhidingCore

// 原 AXSubrole 写入路线已撤下：SDK 将该属性定义为只读类型描述，而非层级。
// 保留说明入口，避免用户继续为不可实现的能力反复授权。

@MainActor
extension AppCoordinator {
    func selectWindowPin() {
        guard !terminating else { return }
        notice = WindowPinPolicy.title
        guard !smokeMode else { return }
        if pinPickerWindow == nil {
            pinPickerWindow = makeWindow(title: WindowPinPolicy.title,
                view: AnyView(WindowPinUnavailableView(onMirror: { [weak self] in
                    self?.pinPickerWindow?.orderOut(nil)
                    self?.selectMirror()
                })), size: CGSize(width: 560, height: 380))
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = pinPickerWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
