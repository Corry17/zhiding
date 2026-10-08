import AppKit
import Carbon
import Combine

enum AppCommand: UInt32, CaseIterable, Codable {
    case screenshot = 1, mirror, paste, toggleAll
    var title: String {
        switch self {
        case .screenshot: return "区域截图并置顶"
        case .mirror: return "选择窗口镜像"
        case .paste: return "从剪贴板贴图"
        case .toggleAll: return "全部隐藏/显示"
        }
    }
}

struct KeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled: Bool
    var display: String {
        let key = HotKeyService.keys.first { $0.1 == keyCode }?.0 ?? "?"
        return (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
            (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
            (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
            (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + key
    }
}

@MainActor
final class HotKeyService: ObservableObject {
    nonisolated static let keys: [(String, UInt32)] = [
        ("0", 29), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
        ("6", 22), ("7", 26), ("8", 28), ("9", 25),
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5),
        ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45),
        ("O", 31), ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17),
        ("U", 32), ("V", 9), ("W", 13), ("X", 7), ("Y", 16), ("Z", 6)
    ]
    @Published var bindings: [AppCommand: KeyBinding] = [:]
    @Published var registrationMessage = ""
    var onCommand: ((AppCommand) -> Void)?
    private var registrations: [AppCommand: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    init() {
        let defaults: [UInt32] = [18, 19, 20, 29]
        for (index, command) in AppCommand.allCases.enumerated() {
            let stored = UserDefaults.standard.data(forKey: "shortcut.\(command.rawValue)")
                .flatMap { try? JSONDecoder().decode(KeyBinding.self, from: $0) }
            bindings[command] = stored ?? KeyBinding(keyCode: defaults[index], modifiers: UInt32(optionKey | cmdKey), enabled: true)
        }
    }

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  let command = AppCommand(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { [weak service] in service?.onCommand?(command) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard result == noErr else { registrationMessage = "快捷键初始化失败，请使用菜单。"; return }
        for command in AppCommand.allCases {
            if let binding = bindings[command] {
                do { try apply(binding, to: command, persist: false) }
                catch { registrationMessage = "部分快捷键无法注册，请修改组合或使用菜单。" }
            }
        }
    }

    func apply(_ binding: KeyBinding, to command: AppCommand, persist: Bool = true) throws {
        if binding.enabled {
            let primary = UInt32(cmdKey | optionKey | controlKey)
            guard binding.modifiers & primary != 0,
                  Self.keys.contains(where: { $0.1 == binding.keyCode }),
                  binding.modifiers & ~UInt32(cmdKey | optionKey | controlKey | shiftKey) == 0 else { throw HotKeyError.invalid }
            // 保留常用系统组合；注册结果仍不能反映所有应用的内部快捷键。
            if binding.modifiers == UInt32(cmdKey) ||
                (binding.modifiers == UInt32(cmdKey | shiftKey) && [20, 21, 23].contains(binding.keyCode)) ||
                (binding.modifiers == UInt32(cmdKey | controlKey) && binding.keyCode == 12) { throw HotKeyError.invalid }
            for (other, existing) in bindings where other != command && registrations[other] != nil {
                if existing.keyCode == binding.keyCode && existing.modifiers == binding.modifiers { throw HotKeyError.conflict }
            }
            if binding == bindings[command], registrations[command] != nil { return }
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                             EventHotKeyID(signature: 0x5A484447, id: command.rawValue),
                                             GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else { throw HotKeyError.conflict }
            if let old = registrations[command] { UnregisterEventHotKey(old) }
            registrations[command] = reference
        } else if let old = registrations.removeValue(forKey: command) { UnregisterEventHotKey(old) }
        bindings[command] = binding
        if persist, let data = try? JSONEncoder().encode(binding) { UserDefaults.standard.set(data, forKey: "shortcut.\(command.rawValue)") }
    }

    func stop() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}

enum HotKeyError: LocalizedError {
    case invalid, conflict
    var errorDescription: String? {
        self == .invalid ? "组合不支持或被系统保留，请使用含 ⌘、⌥ 或 ⌃ 的其他组合。" : "快捷键已被占用或无法注册，原设置保持不变。"
    }
}
