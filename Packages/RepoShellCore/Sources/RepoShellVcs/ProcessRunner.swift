import Foundation

public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data

    public var stdoutString: String {
        String(data: stdoutData, encoding: .utf8)
            ?? String(decoding: stdoutData, as: UTF8.self)
    }

    public var stderrString: String {
        String(data: stderrData, encoding: .utf8)
            ?? String(decoding: stderrData, as: UTF8.self)
    }
}

private final class ProcessCollectorBox: @unchecked Sendable {
    private let lock = NSLock()
    var stdoutData = Data()
    var stderrData = Data()
    private var stdoutLineBuffer = Data()
    private var stderrLineBuffer = Data()
    private var finished = false
    private let onOutputLine: (@Sendable (String, Bool) -> Void)?

    init(onOutputLine: (@Sendable (String, Bool) -> Void)?) {
        self.onOutputLine = onOutputLine
    }

    func appendStdout(_ chunk: Data) {
        lock.lock()
        stdoutData.append(chunk)
        let lines = extractLines(from: &stdoutLineBuffer, appending: chunk)
        lock.unlock()
        if let onOutputLine = onOutputLine {
            for line in lines {
                onOutputLine(line, false)
            }
        }
    }

    func appendStderr(_ chunk: Data) {
        lock.lock()
        stderrData.append(chunk)
        let lines = extractLines(from: &stderrLineBuffer, appending: chunk)
        lock.unlock()
        if let onOutputLine = onOutputLine {
            for line in lines {
                onOutputLine(line, true)
            }
        }
    }

    func flushRemainingLines() {
        lock.lock()
        let outRest = String(data: stdoutLineBuffer, encoding: .utf8)
        let errRest = String(data: stderrLineBuffer, encoding: .utf8)
        stdoutLineBuffer.removeAll()
        stderrLineBuffer.removeAll()
        lock.unlock()

        if let onOutputLine = onOutputLine {
            if let outRest = outRest, !outRest.isEmpty {
                onOutputLine(outRest, false)
            }
            if let errRest = errRest, !errRest.isEmpty {
                onOutputLine(errRest, true)
            }
        }
    }

    func markFinishedIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    private func extractLines(from buffer: inout Data, appending chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[..<newlineIndex]
            if let str = String(data: lineData, encoding: .utf8), !str.isEmpty {
                lines.append(str)
            }
            let nextIndex = buffer.index(after: newlineIndex)
            buffer.removeSubrange(..<nextIndex)
        }
        return lines
    }
}

public enum ProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        standardInputData: Data? = nil,
        onOutputLine: (@Sendable (String, Bool) -> Void)? = nil
    ) async throws -> ProcessOutput {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let workingDirectory = workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        var mergedEnv = ProcessInfo.processInfo.environment
        mergedEnv["LC_ALL"] = "en_US.UTF-8"
        mergedEnv["LANG"] = "en_US.UTF-8"
        if let environment = environment {
            for (k, v) in environment {
                mergedEnv[k] = v
            }
        }
        process.environment = mergedEnv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if standardInputData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        let collector = ProcessCollectorBox(onOutputLine: onOutputLine)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outHandle = stdoutPipe.fileHandleForReading
                let errHandle = stderrPipe.fileHandleForReading

                let group = DispatchGroup()
                group.enter()
                group.enter()

                outHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        group.leave()
                    } else {
                        collector.appendStdout(data)
                    }
                }

                errHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        group.leave()
                    } else {
                        collector.appendStderr(data)
                    }
                }

                process.terminationHandler = { proc in
                    group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                        outHandle.readabilityHandler = nil
                        errHandle.readabilityHandler = nil
                        collector.flushRemainingLines()
                        guard collector.markFinishedIfFirst() else { return }
                        if Task.isCancelled {
                            continuation.resume(throwing: VcsError.cancelled)
                        } else {
                            continuation.resume(returning: ProcessOutput(
                                exitCode: proc.terminationStatus,
                                stdoutData: collector.stdoutData,
                                stderrData: collector.stderrData
                            ))
                        }
                    }
                }

                do {
                    try process.run()
                    if let stdinPipe = stdinPipe, let data = standardInputData {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                } catch {
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    if collector.markFinishedIfFirst() {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
