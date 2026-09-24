import Darwin
import Foundation
import Testing

@Suite("CLI contract", .serialized)
struct CLIContractTests {
  @Test("read writes exact bytes")
  func readWritesExactBytes() throws {
    let fixture = try CLIFixture()
    let bytes = Data([0, 102, 111, 111, 10, 255])
    let target = try fixture.write("target", bytes)

    let result = try fixture.run(["read", target.path])

    #expect(result.status == 0)
    #expect(result.stdout == bytes)
    #expect(result.stderr.isEmpty)
  }

  @Test("read rejects a symbolic link")
  func readRejectsSymbolicLink() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "must not be emitted")
    let link = fixture.file("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let result = try fixture.run(["read", link.path])

    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("invalid_target"))
  }

  @Test("read reports a missing file")
  func readReportsMissingFile() throws {
    let fixture = try CLIFixture()

    let result = try fixture.run(["read", fixture.file("missing").path])

    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("not_found"))
  }

  @Test("read reports permission denied")
  func readReportsPermissionDenied() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "private contents")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    let result = try fixture.run(["read", target.path])

    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("permission_denied"))
  }

  @Test("read and replace reject a FIFO target without waiting", arguments: ["read", "replace"])
  func commandsRejectFIFOTarget(_ command: String) throws {
    let fixture = try CLIFixture()
    let target = fixture.file("fifo")
    let source = try fixture.write("source", "replacement contents")
    try fixture.makeFIFO(at: target)
    let arguments =
      command == "read"
      ? ["read", target.path]
      : ["replace", target.path, "--from", source.path]

    let result = try fixture.run(arguments, timeout: 2)

    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("invalid_target"))
  }

  @Test("replace installs a completed source file")
  func replaceFromFile() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "old contents")
    let source = try fixture.write("source", "new contents\n")

    let result = try fixture.run(["replace", target.path, "--from", source.path])

    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.isEmpty)
    #expect(try Data(contentsOf: target) == Data(contentsOf: source))
  }

  @Test("replace installs standard input")
  func replaceFromStandardInput() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "old contents")
    let source = try fixture.write("source", "piped replacement\n")

    let result = try fixture.run(["replace", target.path, "--from", "-"], input: source)

    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.isEmpty)
    #expect(try Data(contentsOf: target) == Data(contentsOf: source))
  }

  @Test("replace rejects empty standard input")
  func replaceRejectsEmptyStandardInput() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "keep these contents")

    let result = try fixture.run(["replace", target.path, "--from", "-"])

    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("invalid_source"))
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep these contents")
  }

  @Test("replace rejects a directory source")
  func replaceRejectsDirectorySource() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "keep these contents")
    let source = fixture.file("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)

    let result = try fixture.run(["replace", target.path, "--from", source.path])

    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("invalid_source"))
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep these contents")
  }

  @Test("replace rejects a FIFO source without waiting")
  func replaceRejectsFIFOSource() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "keep these contents")
    let source = fixture.file("fifo-source")
    try fixture.makeFIFO(at: source)

    let result = try fixture.run(["replace", target.path, "--from", source.path], timeout: 2)

    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("invalid_source"))
    #expect(try String(contentsOf: target, encoding: .utf8) == "keep these contents")
  }

  @Test("replace reports missing source and target files")
  func replaceReportsMissingPaths() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "current contents")
    let source = fixture.file("source")

    let missingSource = try fixture.run(["replace", target.path, "--from", source.path])
    #expect(missingSource.status == 1)
    #expect(missingSource.hasDiagnostic("not_found"))
    #expect(missingSource.stdout.isEmpty)

    try Data("replacement contents".utf8).write(to: source)
    let missingTarget = try fixture.run([
      "replace", fixture.file("missing-target").path, "--from", source.path,
    ])
    #expect(missingTarget.status == 1)
    #expect(missingTarget.hasDiagnostic("not_found"))
    #expect(missingTarget.stdout.isEmpty)
    #expect(try String(contentsOf: target, encoding: .utf8) == "current contents")
  }

  @Test("replace reports an unchanged commit failure")
  func replaceReportsUnchangedCommitFailure() throws {
    let fixture = try CLIFixture()
    let parent = fixture.file("read-only-parent")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let target = parent.appendingPathComponent("target")
    try Data("current contents".utf8).write(to: target)
    let source = try fixture.write("source", "replacement contents")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    }

    let result = try fixture.run(["replace", target.path, "--from", source.path])

    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("permission_denied"))
    #expect(!result.errorText.contains("replacement outcome is uncertain"))
    #expect(try String(contentsOf: target, encoding: .utf8) == "current contents")
  }

  @Test("failed replacement removes staged contents")
  func failedReplacementRemovesStagedContents() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "current contents")
    let marker = "filecoord-staged-marker-\(UUID().uuidString)"
    let source = try fixture.write("source", marker)
    let temporaryItems = FileManager.default.temporaryDirectory
      .appendingPathComponent("TemporaryItems", isDirectory: true)
    let existingItems = try fixture.items(in: temporaryItems)

    let addACL = try fixture.run(
      ["+a", "everyone deny delete", target.path],
      executable: URL(fileURLWithPath: "/bin/chmod")
    )
    try #require(addACL.status == 0)
    defer {
      _ = try? fixture.run(
        ["-N", target.path],
        executable: URL(fileURLWithPath: "/bin/chmod")
      )
    }

    let result = try fixture.run(["replace", target.path, "--from", source.path])
    let newItems = try fixture.items(in: temporaryItems).subtracting(existingItems)

    #expect(FileManager.default.fileExists(atPath: temporaryItems.path))
    #expect(result.status == 1)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("permission_denied"))
    #expect(try String(contentsOf: target, encoding: .utf8) == "current contents")
    #expect(!fixture.contains(marker, in: newItems))
  }

  @Test("replace rejects a stale SHA-256 precondition")
  func replaceRejectsStalePrecondition() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "current contents")
    let source = try fixture.write("source", "replacement contents")
    let staleHash = "sha256:" + String(repeating: "0", count: 64)

    let result = try fixture.run([
      "replace", target.path, "--from", source.path, "--if-match", staleHash,
    ])

    #expect(result.status == 3)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("precondition_failed"))
    #expect(try String(contentsOf: target, encoding: .utf8) == "current contents")
  }

  @Test("replace accepts a matching SHA-256 precondition")
  func replaceAcceptsMatchingPrecondition() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "current contents")
    let source = try fixture.write("source", "replacement contents")
    let currentHash = "sha256:b7774c0323764a9bc61862f58a725ec65b55ef19173a72a0044e6395f5d487ae"

    let result = try fixture.run([
      "replace", target.path, "--from", source.path, "--if-match", currentHash,
    ])

    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.isEmpty)
    #expect(try Data(contentsOf: target) == Data(contentsOf: source))
  }

  @Test("replace rejects a precondition after pending edits are saved")
  func replaceRejectsPreconditionAfterPresenterSaves() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "current contents")
    let source = try fixture.write("source", "replacement contents")
    let presenter = SavingPresenter(url: target, contents: "pending edits")
    NSFileCoordinator.addFilePresenter(presenter)
    defer { NSFileCoordinator.removeFilePresenter(presenter) }

    let result = try fixture.run([
      "replace", target.path, "--from", source.path,
      "--if-match", "sha256:b7774c0323764a9bc61862f58a725ec65b55ef19173a72a0044e6395f5d487ae",
    ])

    #expect(result.status == 3)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("precondition_failed"))
    #expect(try String(contentsOf: target, encoding: .utf8) == "pending edits")
  }

  @Test("replace accepts an explicit empty file")
  func replaceAcceptsEmptyFile() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "contents to remove")
    let source = try fixture.write("source", Data())

    let result = try fixture.run(["replace", target.path, "--from", source.path])

    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.isEmpty)
    #expect(try Data(contentsOf: target).isEmpty)
  }

  @Test("replace rejects symbolic and multiply linked targets")
  func replaceRejectsLinkedTargets() throws {
    let fixture = try CLIFixture()
    let original = try fixture.write("original", "keep linked contents")
    let hardLink = fixture.file("hard-link")
    let symbolicLink = fixture.file("symbolic-link")
    let source = try fixture.write("source", "replacement contents")
    try FileManager.default.linkItem(at: original, to: hardLink)
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: original)

    for target in [hardLink, symbolicLink] {
      let result = try fixture.run(["replace", target.path, "--from", source.path])
      #expect(result.status == 1)
      #expect(result.stdout.isEmpty)
      #expect(result.hasDiagnostic("invalid_target"))
    }
    #expect(try String(contentsOf: original, encoding: .utf8) == "keep linked contents")
  }

  @Test("invalid arguments return usage status")
  func invalidArgumentsReturnUsageStatus() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "current contents")
    let source = try fixture.write("source", "replacement contents")

    let invalidTimeout = try fixture.run(["read", target.path, "--timeout", "0"])
    #expect(invalidTimeout.status == 64)
    #expect(invalidTimeout.stdout.isEmpty)

    let invalidHash = try fixture.run([
      "replace", target.path, "--from", source.path, "--if-match", "sha256:xyz",
    ])
    #expect(invalidHash.status == 64)
    #expect(invalidHash.stdout.isEmpty)
    #expect(try String(contentsOf: target, encoding: .utf8) == "current contents")
  }

  @Test("non-ASCII SHA-256 preconditions are invalid usage")
  func nonASCIIPreconditionIsInvalidUsage() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "current contents")
    let source = try fixture.write("source", "replacement contents")
    let nonASCIIHash = "sha256:" + String(repeating: "０", count: 64)

    let result = try fixture.run([
      "replace", target.path, "--from", source.path, "--if-match", nonASCIIHash,
    ])

    #expect(result.status == 64)
    #expect(result.stdout.isEmpty)
    #expect(try String(contentsOf: target, encoding: .utf8) == "current contents")
  }

  @Test("help describes the process contract")
  func helpDescribesProcessContract() throws {
    let fixture = try CLIFixture()
    let root = try fixture.run(["--help"])
    let read = try fixture.run(["read", "--help"])
    let replace = try fixture.run(["replace", "--help"])

    #expect(root.status == 0)
    #expect(read.status == 0)
    #expect(replace.status == 0)
    #expect(String(decoding: root.stdout, as: UTF8.self).contains("filecoord: CODE: MESSAGE"))
    #expect(String(decoding: read.stdout, as: UTF8.self).contains("partial bytes"))
    #expect(String(decoding: replace.stdout, as: UTF8.self).contains("commit_failed"))
    #expect(String(decoding: replace.stdout, as: UTF8.self).contains("cleanup_failed"))
  }

  @Test("read uses bounded memory for a large file")
  func readUsesBoundedMemory() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("large", Data())
    let handle = try FileHandle(forWritingTo: target)
    try handle.truncate(atOffset: 128 * 1024 * 1024)
    try handle.close()

    let result = try fixture.run(
      ["-l", CLIFixture.product("filecoord").path, "read", target.path],
      executable: URL(fileURLWithPath: "/usr/bin/time"),
      discardOutput: true,
      timeout: 30
    )
    let line = try #require(
      result.errorText.split(separator: "\n").first {
        $0.contains("maximum resident set size")
      })
    let residentBytes = try #require(Int(line.split(whereSeparator: \.isWhitespace).first ?? ""))

    #expect(result.status == 0)
    #expect(residentBytes < 96 * 1024 * 1024)
  }

  @Test("read times out while waiting for coordinated access")
  func readTimesOutWhileWaitingForCoordination() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "blocked contents")
    let presenter = BlockingPresenter(url: target)
    NSFileCoordinator.addFilePresenter(presenter)
    defer {
      presenter.unblock()
      NSFileCoordinator.removeFilePresenter(presenter)
    }

    let result = try fixture.run(["read", target.path, "--timeout", "0.1"])

    #expect(result.status == 124)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("timed_out"))
  }

  @Test("replace times out without changing the target")
  func replaceTimesOutWhileWaitingForCoordination() throws {
    let fixture = try CLIFixture()
    let target = try fixture.write("target", "blocked contents")
    let source = try fixture.write("source", "replacement contents")
    let presenter = BlockingPresenter(url: target)
    NSFileCoordinator.addFilePresenter(presenter)
    defer {
      presenter.unblock()
      NSFileCoordinator.removeFilePresenter(presenter)
    }

    let result = try fixture.run([
      "replace", target.path, "--from", source.path, "--timeout", "0.1",
    ])

    #expect(result.status == 124)
    #expect(result.stdout.isEmpty)
    #expect(result.hasDiagnostic("timed_out"))
    #expect(try String(contentsOf: target, encoding: .utf8) == "blocked contents")
  }
}

private final class CLIFixture {
  let directory: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("filecoord-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  func file(_ name: String) -> URL {
    directory.appendingPathComponent(name)
  }

  func write(_ name: String, _ bytes: Data) throws -> URL {
    let url = file(name)
    try bytes.write(to: url)
    return url
  }

  func write(_ name: String, _ text: String) throws -> URL {
    try write(name, Data(text.utf8))
  }

  func makeFIFO(at url: URL) throws {
    guard mkfifo(url.path, 0o600) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  func items(in directory: URL) throws -> Set<URL> {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return Set(
      try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      ))
  }

  func contains(_ marker: String, in directories: Set<URL>) -> Bool {
    for candidateDirectory in directories {
      guard
        let enumerator = FileManager.default.enumerator(
          at: candidateDirectory,
          includingPropertiesForKeys: [.isRegularFileKey]
        )
      else { continue }
      for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
          let data = try? Data(contentsOf: url)
        else { continue }
        if String(data: data, encoding: .utf8)?.contains(marker) == true { return true }
      }
    }
    return false
  }

  func run(
    _ arguments: [String],
    executable: URL? = nil,
    input: URL? = nil,
    discardOutput: Bool = false,
    timeout: TimeInterval = 10
  ) throws -> CLIResult {
    let stdoutURL = file("stdout-\(UUID().uuidString)")
    let stderrURL = file("stderr-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
      FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw CLIHarnessError.cannotCreateOutput
    }
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    let stdin = try input.map(FileHandle.init(forReadingFrom:))
    defer {
      try? stdout.close()
      try? stderr.close()
      try? stdin?.close()
    }

    let process = Process()
    process.executableURL = executable ?? Self.product("filecoord")
    process.arguments = arguments
    process.standardInput = stdin ?? FileHandle.nullDevice
    process.standardOutput = discardOutput ? FileHandle.nullDevice : stdout
    process.standardError = stderr
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
      _ = kill(process.processIdentifier, SIGTERM)
      process.waitUntilExit()
      throw CLIHarnessError.processTimedOut(arguments)
    }
    process.waitUntilExit()

    return try CLIResult(
      status: process.terminationStatus,
      stdout: discardOutput ? Data() : Data(contentsOf: stdoutURL),
      stderr: Data(contentsOf: stderrURL)
    )
  }

  static func product(_ name: String) -> URL {
    let bundle = Bundle(for: CLIFixture.self)
    return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name)
  }
}

private struct CLIResult {
  let status: Int32
  let stdout: Data
  let stderr: Data

  var errorText: String { String(decoding: stderr, as: UTF8.self) }

  func hasDiagnostic(_ code: String) -> Bool {
    errorText.contains("filecoord: \(code):")
  }
}

private enum CLIHarnessError: Error {
  case cannotCreateOutput
  case processTimedOut([String])
}

private final class BlockingPresenter: NSObject, NSFilePresenter {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  private let gate = DispatchSemaphore(value: 0)

  init(url: URL) {
    presentedItemURL = url
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
  }

  func savePresentedItemChanges(completionHandler: @escaping ((any Error)?) -> Void) {
    gate.wait()
    completionHandler(nil)
  }

  func unblock() {
    gate.signal()
  }
}

private final class SavingPresenter: NSObject, NSFilePresenter {
  let presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue()
  private let url: URL
  private let contents: Data

  init(url: URL, contents: String) {
    presentedItemURL = url
    self.url = url
    self.contents = Data(contents.utf8)
    presentedItemOperationQueue.maxConcurrentOperationCount = 1
  }

  func savePresentedItemChanges(completionHandler: @escaping ((any Error)?) -> Void) {
    do {
      try contents.write(to: url)
      completionHandler(nil)
    } catch {
      completionHandler(error)
    }
  }
}
