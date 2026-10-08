import SwiftUI
import AppKit
import Carbon
import ZhidingCore

struct ManagerView: View {
    @ObservedObject var app: AppCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "pin.square.fill").font(.system(size: 36)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("参考，就放眼前").font(.title2.bold())
                    Text("多张截图独立置顶，窗口镜像仅供查看。内容不会自动保存。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if app.isBusy { ProgressView().controlSize(.small) }
            }.padding(24)
            HStack(spacing: 12) {
                Button("区域截图", systemImage: "viewfinder") { app.captureRegion() }
                Button("窗口镜像", systemImage: "macwindow.on.rectangle") { app.selectMirror() }
                Button("原窗口置顶说明", systemImage: "info.circle") { app.selectWindowPin() }
                    .help("此能力暂不可用，点击查看原因；无需申请辅助功能权限")
                Button("粘贴图片", systemImage: "doc.on.clipboard") { app.pasteImage() }
                Button("导入图片", systemImage: "photo") { app.importImage() }
            }.buttonStyle(.bordered).padding(.horizontal, 24).padding(.bottom, 18)
            if app.isBusy {
                Text("正在选择或处理内容，请先完成或取消当前选择；无需关闭已有贴图。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
            }
            if let notice = app.notice {
                HStack {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("关闭提示") { app.notice = nil }
                }.padding(.horizontal, 24).padding(.vertical, 10)
            }
            Divider()
            if app.privacyHidden {
                VStack(spacing: 12) {
                    Image(systemName: "eye.slash.fill").font(.largeTitle).foregroundStyle(.secondary)
                    Text("内容已隐藏，镜像已请求停止").font(.headline)
                    Text("保护原因：\(app.privacyReason)").foregroundStyle(.secondary)
                    Text("可直接点击上方功能，确认恢复后继续。取消则保持隐藏。\n恢复不会自动重启镜像，也不会显示手动隐藏的贴图。")
                        .multilineTextAlignment(.center)
                    Button("恢复显示") { app.resumePrivacy() }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.records.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.on.square.dashed").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text("还没有置顶内容").font(.headline)
                    Text("点击区域截图，或复制图片后按 ⌥⌘3。\n本机开发版：锁屏与全屏兼容性仍待实测。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(app.records) { record in
                            PinRow(record: record, app: app)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("\(app.records.count) 个内容 · 隐藏镜像仍可能在捕获").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(app.privacyHidden ? "恢复显示…" : "全部隐藏/显示") { app.toggleAll() }.disabled(app.records.isEmpty)
                Button("解除穿透") { app.clearAllPassThrough() }
                Button("关闭全部…") { app.closeAllConfirmed() }.disabled(app.records.isEmpty)
            }.padding(16)
        }.frame(minWidth: 760, minHeight: 520)
    }
}

private struct PinRow: View {
    @ObservedObject var record: PinRecord
    @ObservedObject var app: AppCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: record.kind == .mirror ? "macwindow" : "photo")
                    .font(.title2).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name).font(.headline)
                    Text("\(record.status) · \(record.hidden ? "隐藏" : "显示")\(record.clickThrough ? " · 穿透" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let time = record.lastFrameAt {
                        Text("最后更新 \(time.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("定位") { app.locate(record) }
                Button(record.hidden ? "显示" : "隐藏") { app.setHidden(record, !record.hidden) }
                if record.kind == .screenshot {
                    Button("复制") { app.export(record, toClipboard: true) }
                    Button("保存") { app.export(record, toClipboard: false) }
                } else {
                    Button("转贴图") { app.freeze(record) }.disabled(record.renderer?.hasFrame != true)
                    Button("停止后重选") { app.selectMirror(replacing: record) }
                    Button("停止") { Task { await app.stopMirror(record, clear: false) } }
                }
                Button(role: .destructive) { Task { await app.close(record) } } label: { Image(systemName: "xmark") }
                    .help("关闭并丢弃此内容")
            }
            HStack(spacing: 12) {
                Text("透明度 \(Int(record.opacity * 100))%").font(.caption).frame(width: 86, alignment: .leading)
                Slider(value: $record.opacity, in: 0.2...1, step: 0.05).frame(width: 150)
                Toggle("鼠标穿透", isOn: Binding(get: { record.clickThrough }, set: {
                    record.clickThrough = $0; record.panel?.ignoresMouseEvents = $0; app.refresh()
                })).toggleStyle(.checkbox)
                Spacer()
                if record.hasUnsavedImage { Text("未导出").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(16).disabled(record.closing)
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppCoordinator
    @ObservedObject var hotkeys: HotKeyService
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("快捷键").font(.title2.bold())
                Text("修改成功后生效；注册失败保留原设置。使用菜单不需要快捷键权限。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(AppCommand.allCases, id: \.rawValue) { command in
                    if let binding = hotkeys.bindings[command] {
                        ShortcutEditor(command: command, initial: binding, service: hotkeys)
                    }
                }
                if !hotkeys.registrationMessage.isEmpty { Text(hotkeys.registrationMessage).foregroundStyle(.orange) }
                Divider()
                Text(WindowPinPolicy.title).font(.headline)
                Text(WindowPinPolicy.explanation).foregroundStyle(.secondary)
                Button("查看原窗口置顶说明") { app.selectWindowPin() }
                Divider()
                Text("权限与隐私").font(.headline)
                Text("区域截图需要屏幕录制权限；窗口镜像使用系统选择器的会话授权；图片导入无需屏幕权限。原窗口置顶路线已停用，不再请求辅助功能。不会申请输入监控、摄像头或麦克风权限。")
                HStack {
                    Button("打开屏幕录制设置") { app.openScreenRecordingSettings() }
                    Button("查看已有辅助功能授权") { app.openAccessibilitySettings() }
                    Button("隐私与安全设置") { app.openPrivacySecuritySettings() }
                }
                Text("辅助功能入口仅供查看或自行撤销旧版授权，不会申请、重置或替你更改权限。")
                    .foregroundStyle(.secondary)
                Divider()
                Text("本机开发版 0.1").font(.headline)
                Text("macOS 14+ · 最多 20 张贴图 / 3 个镜像 · 512 MiB 图像资源估算预算。图片只在内存中保留；退出不自动恢复。关闭单张贴图会直接丢弃。")
                Text("镜像采用先停止再重新选择的保守流程，只能查看。原窗口可操作置顶尚未实现。锁屏、全屏、混合缩放屏和真实捕获尚需验收；Release 构建暂不开放镜像，不是可对外分发的正式版。")
                    .foregroundStyle(.secondary)
            }.font(.callout).padding(24)
        }.frame(minWidth: 630, minHeight: 560)
    }
}

private struct ShortcutEditor: View {
    let command: AppCommand
    @ObservedObject var service: HotKeyService
    @State private var draft: KeyBinding
    @State private var error = ""
    init(command: AppCommand, initial: KeyBinding, service: HotKeyService) {
        self.command = command; self.service = service
        _draft = State(initialValue: initial)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(command.title).font(.headline)
            HStack {
                Toggle("启用", isOn: $draft.enabled).toggleStyle(.checkbox)
                modifier("⌘", cmdKey)
                modifier("⌥", optionKey)
                modifier("⌃", controlKey)
                modifier("⇧", shiftKey)
                Picker("按键", selection: $draft.keyCode) {
                    ForEach(HotKeyService.keys, id: \.1) { Text($0.0).tag($0.1) }
                }.labelsHidden().frame(width: 64)
                Spacer()
                Button("应用") {
                    do { try service.apply(draft, to: command); error = "已生效" }
                    catch { self.error = error.localizedDescription }
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func modifier(_ title: String, _ mask: Int) -> some View {
        Toggle(title, isOn: Binding(get: { draft.modifiers & UInt32(mask) != 0 }, set: {
            if $0 { draft.modifiers |= UInt32(mask) } else { draft.modifiers &= ~UInt32(mask) }
        })).toggleStyle(.checkbox)
    }
}
