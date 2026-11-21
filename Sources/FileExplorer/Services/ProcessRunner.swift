import Foundation

/// Thread-safe handle for cancelling a running process.
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func attach(_ proc: Process) {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            proc.terminate()
        } else {
            self.process = proc
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        process?.terminate()
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

/// Runs a system tool without a shell. Arguments are passed as an array, never
/// interpolated into a command line, so file names can't inject options or commands.
enum ProcessRunner {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stderrText: String {
            String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    static func run(_ executable: String, _ arguments: [String], currentDirectory: String? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let dir = currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: dir) }
        // Minimal, fixed environment: nothing inherited can change a tool's behaviour.
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Drain stderr concurrently so a chatty tool can never block on a full pipe.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: out, stderr: errBox.data)
    }

    /// Like `run`, but hands each stdout line to `onOutputLine` as it arrives.
    /// When `onOutputLine` is set, stdout is consumed line by line and not kept in memory
    /// (`Output.stdout` is empty), so a verbose tool listing every file can't grow the heap.
    static func runStreaming(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: String? = nil,
        handle: ProcessHandle? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let dir = currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: dir) }
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outBox = DataBox(), errBox = DataBox()
        let lines = onOutputLine.map(LineSplitter.init)
        let errLock = NSLock()
        let errLines = onOutputLine.map(LineSplitter.init)
        let group = DispatchGroup()

        group.enter()
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else {                     // EOF
                fh.readabilityHandler = nil
                errLines?.finish()
                group.leave()
                return
            }
            errLock.lock()
            errBox.data.append(chunk)
            errLock.unlock()
            errLines?.append(chunk)
        }

        // readabilityHandler calls are serial per handle, so the buffers need no lock.
        group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else {                     // EOF
                fh.readabilityHandler = nil
                lines?.finish()
                group.leave()
                return
            }
            if let lines { lines.append(chunk) } else { outBox.data.append(chunk) }
        }

        handle?.attach(process)
        do {
            try process.run()
        } catch {
            // Nothing will ever write to the pipes; close them so the readers above finish.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw error
        }
        process.waitUntilExit()
        group.wait()

        return Output(status: process.terminationStatus, stdout: outBox.data, stderr: errBox.data)
    }

    /// Splits a byte stream into lines on "\n". Works on bytes, so a multi-byte UTF-8
    /// character split across two reads is decoded correctly once both halves arrived.
    private final class LineSplitter: @unchecked Sendable {
        private var buffer = Data()
        private let onLine: @Sendable (String) -> Void

        init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

        func append(_ chunk: Data) {
            buffer.append(chunk)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                onLine(String(decoding: buffer[lineStart..<newline], as: UTF8.self))
                lineStart = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }

        func finish() {
            guard !buffer.isEmpty else { return }
            onLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
    }
}
