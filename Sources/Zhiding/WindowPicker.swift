import AppKit
import ScreenCaptureKit
import ZhidingCore

@MainActor
final class WindowPicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<SCContentFilter, Error>?
    private(set) var isPresenting = false
    private var cancelled = false
    var streamCount = 0 { didSet { refreshActivity() } }
    var onUnexpectedChange: ((SCStream) -> Void)?

    override init() {
        super.init()
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "local.zhiding.dev"]
        // 开发版采用停止后重新选择，避免未验证的同流换源边界造成混帧。
        config.allowsChangingSelectedContent = false
        picker.defaultConfiguration = config
        picker.maximumStreamCount = Limits.mirrors
        picker.add(self)
    }

    func pick() async throws -> SCContentFilter {
        guard !isPresenting else { throw ZhidingError.cancelled }
        isPresenting = true
        cancelled = false
        SCContentSharingPicker.shared.isActive = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            SCContentSharingPicker.shared.present(using: .window)
        }
    }

    func cancelRequest() {
        guard isPresenting else { return }
        cancelled = true
        continuation?.resume(throwing: ZhidingError.cancelled)
        continuation = nil
        // 不开放下一个请求，直到系统确认旧选择流程结束。
    }

    func shutdown() {
        cancelRequest()
        SCContentSharingPicker.shared.isActive = false
        SCContentSharingPicker.shared.remove(self)
    }

    private func finish(_ result: Result<SCContentFilter, Error>) {
        guard isPresenting else { return }
        let callback = continuation
        continuation = nil
        isPresenting = false
        if !cancelled { callback?.resume(with: result) }
        refreshActivity()
    }

    private func refreshActivity() {
        SCContentSharingPicker.shared.isActive = isPresenting || streamCount > 0
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in self?.finish(.failure(ZhidingError.cancelled)) }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let stream { self.onUnexpectedChange?(stream); return }
            guard filter.style == .window else { self.finish(.failure(ZhidingError.captureFailed)); return }
            self.finish(.success(filter))
        }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in self?.finish(.failure(ZhidingError.captureFailed)) }
    }
}
