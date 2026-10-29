import Foundation

/// Runs command-line tools (`docker`, `xcrun simctl`) with a timeout, off
/// the caller's thread.
public enum CommandRunner {
  public struct Result: Sendable {
    public var status: Int32
    public var output: Data
    public var succeeded: Bool { status == 0 }
  }

  /// Runs `executable` and returns its exit status and standard output, or
  /// nil if it could not start or did not finish within `timeout`.
  public static func run(
    _ executable: String, _ arguments: [String], timeout: TimeInterval
  ) async -> Result? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: runBlocking(executable, arguments, timeout: timeout))
      }
    }
  }

  /// Blocking variant of `run`; never call it on the main thread.
  public static func runBlocking(
    _ executable: String, _ arguments: [String], timeout: TimeInterval
  ) -> Result? {
    guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // GUI apps start with a minimal PATH; tools like docker look up their
    // helpers there.
    var environment = ProcessInfo.processInfo.environment
    let extra = ["/usr/local/bin", "/opt/homebrew/bin", NSHomeDirectory() + "/.docker/bin"]
    environment["PATH"] = ([environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"] + extra)
      .joined(separator: ":")
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      return nil
    }

    // Drain the pipe concurrently so a chatty tool never blocks on a full
    // buffer while we wait for it to exit.
    let output = OutputBuffer()
    let reader = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      output.data = pipe.fileHandleForReading.readDataToEndOfFile()
      reader.signal()
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
      return nil
    }
    _ = reader.wait(timeout: .now() + 2)
    return Result(status: process.terminationStatus, output: output.data)
  }

  /// First executable among `candidates`.
  public static func locate(_ candidates: [String]) -> String? {
    candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}

private final class OutputBuffer: @unchecked Sendable {
  var data = Data()
}
