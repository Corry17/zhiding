import Foundation

// 只生成工作区内的开发应用；不安装、不上传、不公证、不修改系统安全配置。
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let arguments = Set(CommandLine.arguments.dropFirst())
guard arguments.isSubset(of: ["--release", "--universal", "--validation"]) else {
    print("用法：swift Tools/BuildApp.swift [--release] [--universal] [--validation]")
    exit(2)
}
let configuration = arguments.contains("--release") ? "release" : "debug"
#if arch(arm64)
let hostArchitecture = "arm64"
#else
let hostArchitecture = "x86_64"
#endif
let architectures = arguments.contains("--universal") ? ["arm64", "x86_64"] : [hostArchitecture]
let fileManager = FileManager.default
var environment = ProcessInfo.processInfo.environment
let cache = root.appendingPathComponent(".build/cache")
environment["CLANG_MODULE_CACHE_PATH"] = root.appendingPathComponent(".build/clang-cache").path
environment["SWIFT_MODULECACHE_PATH"] = root.appendingPathComponent(".build/swift-cache").path

@discardableResult
func run(_ executable: String, _ arguments: [String], capture: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.environment = environment
    let pipe = capture ? Pipe() : nil
    if let pipe { process.standardOutput = pipe }
    try process.run()
    let output = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw BuildError(message: "命令失败：\(URL(fileURLWithPath: executable).lastPathComponent)，状态 \(process.terminationStatus)")
    }
    return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

struct BuildError: Error { let message: String }

do {
    var binaries: [String] = []
    for architecture in architectures {
        let scratch = root.appendingPathComponent(".build/\(architecture)-bundle")
        let common = ["swift", "build", "--package-path", root.path, "--scratch-path", scratch.path,
                      "--cache-path", cache.path, "--configuration", configuration,
                      "--triple", "\(architecture)-apple-macosx14.0"]
        try run("/usr/bin/xcrun", common + ["--product", "Zhiding"])
        let binaryDirectory = try run("/usr/bin/xcrun", common + ["--show-bin-path"], capture: true)
        binaries.append(URL(fileURLWithPath: binaryDirectory).appendingPathComponent("Zhiding").path)
    }
    let folder = configuration == "debug" ? "Debug" : "Release"
    // 回归验证单独输出，避免替换用户正在运行并已授权的应用包。
    let output = arguments.contains("--validation") ? "build/Validation" : "build"
    let app = root.appendingPathComponent("\(output)/\(folder)/Zhiding.app")
    let contents = app.appendingPathComponent("Contents")
    let macOS = contents.appendingPathComponent("MacOS")
    try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
    let executable = macOS.appendingPathComponent("Zhiding")
    if binaries.count == 1 {
        try Data(contentsOf: URL(fileURLWithPath: binaries[0])).write(to: executable, options: .atomic)
    } else {
        try run("/usr/bin/lipo", binaries + ["-create", "-output", executable.path])
    }
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    try run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", "--entitlements",
                                  root.appendingPathComponent("Resources/Zhiding.entitlements").path, app.path])
    try run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", app.path])
    print("开发应用已生成：\(app.path)")
    print("这是本机 ad hoc 签名，不是 Developer ID 公证发行包。Release 镜像入口禁用；原窗口可操作置顶尚未实现。")
} catch {
    print("构建失败：\(error)")
    exit(1)
}
