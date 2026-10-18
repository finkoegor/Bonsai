import Foundation

/// A command line program the engine drives, such as qpdf or cjpeg.
struct ExternalTool: Sendable {
    let url: URL

    /// Runs the tool to completion, optionally feeding `input` as standard
    /// input and writing standard output to `output`.
    /// Returns the exit status, or nil when the process failed to start or
    /// was stopped after `timeout` seconds.
    @discardableResult
    func run(_ arguments: [String], input: URL? = nil, output: URL? = nil,
             timeout: TimeInterval = 600) -> Int32? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice

        var handles: [FileHandle] = []
        defer { handles.forEach { try? $0.close() } }

        if let input {
            guard let handle = try? FileHandle(forReadingFrom: input) else { return nil }
            handles.append(handle)
            process.standardInput = handle
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: output) else { return nil }
            handles.append(handle)
            process.standardOutput = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
        }

        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationReason == .exit else { return nil }
        return process.terminationStatus
    }

    /// Runs the tool and returns its standard output when it exits with status 0.
    func output(_ arguments: [String]) -> Data? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("bonsai-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: file) }
        guard run(arguments, output: file, timeout: 30) == 0 else { return nil }
        return try? Data(contentsOf: file)
    }
}
