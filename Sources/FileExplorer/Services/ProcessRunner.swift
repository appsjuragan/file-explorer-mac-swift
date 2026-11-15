import Foundation

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
}
