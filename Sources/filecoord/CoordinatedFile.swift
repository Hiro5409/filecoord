import CryptoKit
import Darwin
import Foundation

enum CoordinatedFileError: LocalizedError {
  case invalidTarget(String)
  case invalidSource(String)
  case notFound(String)
  case permissionDenied(String)
  case preconditionFailed
  case timedOut
  case commitFailed(String)

  var code: String {
    switch self {
    case .invalidTarget:
      return "invalid_target"
    case .invalidSource:
      return "invalid_source"
    case .notFound:
      return "not_found"
    case .permissionDenied:
      return "permission_denied"
    case .preconditionFailed:
      return "precondition_failed"
    case .timedOut:
      return "timed_out"
    case .commitFailed:
      return "commit_failed"
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidTarget(let path):
      return "target is not a regular file: \(path)"
    case .invalidSource(let reason):
      return "invalid replacement source: \(reason)"
    case .notFound(let path):
      return "file not found: \(path)"
    case .permissionDenied(let path):
      return "permission denied: \(path)"
    case .preconditionFailed:
      return "target contents do not match the precondition"
    case .timedOut:
      return "coordinated access timed out"
    case .commitFailed(let message):
      return message
    }
  }
}

enum ReplacementSource {
  case file(URL)
  case standardInput
}

enum ContentHash {
  static func normalized(_ value: String) -> String? {
    let prefix = "sha256:"
    guard value.hasPrefix(prefix) else { return nil }
    let hexadecimal = value.dropFirst(prefix.count)
    guard hexadecimal.count == 64,
      hexadecimal.allSatisfy({ $0.isASCII && $0.isHexDigit })
    else {
      return nil
    }
    return hexadecimal.lowercased()
  }

  static func sha256(of input: FileHandle) throws -> String {
    var hash = SHA256()

    while try autoreleasepool(invoking: {
      guard let data = try input.read(upToCount: 64 * 1024), !data.isEmpty else {
        return false
      }
      hash.update(data: data)
      return true
    }) {
      continue
    }

    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

enum CoordinatedFile {
  private static let bufferSize = 64 * 1024

  private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
  }

  static func read(_ url: URL, to output: FileHandle, timeout: TimeInterval) throws {
    try validateTargetMetadata(url, requiresSingleLink: false, timeout: timeout)
    try coordinateReading(url, timeout: timeout) { coordinatedURL in
      let input = try openTargetForReading(coordinatedURL)
      defer { try? input.close() }

      while try autoreleasepool(invoking: {
        guard let data = try input.read(upToCount: bufferSize), !data.isEmpty else {
          return false
        }
        try output.write(contentsOf: data)
        return true
      }) {
        continue
      }
    }
  }

  static func replace(
    _ targetURL: URL,
    from source: ReplacementSource,
    ifMatch expectedHash: String?,
    timeout: TimeInterval
  ) throws {
    try validateTargetMetadata(targetURL, requiresSingleLink: true, timeout: timeout)
    let fileManager = FileManager.default
    let replacementDirectory: URL
    do {
      replacementDirectory = try fileManager.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: targetURL,
        create: true
      )
    } catch {
      throw pathError(error, url: targetURL)
    }
    let stagedURL = replacementDirectory.appendingPathComponent(UUID().uuidString)
    var removesReplacementDirectory = true
    defer {
      if removesReplacementDirectory {
        removeReplacementDirectory(replacementDirectory, stagedURL: stagedURL)
      }
    }

    guard fileManager.createFile(atPath: stagedURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let byteCount = try copy(source, to: stagedURL)
    if case .standardInput = source, byteCount == 0 {
      throw CoordinatedFileError.invalidSource("standard input is empty")
    }

    if let expectedHash {
      try coordinateReading(targetURL, timeout: timeout) { coordinatedURL in
        let input = try openTargetForReading(coordinatedURL)
        defer { try? input.close() }
        guard try ContentHash.sha256(of: input) == expectedHash else {
          throw CoordinatedFileError.preconditionFailed
        }
      }
    }

    try coordinateWriting(targetURL, timeout: timeout) { coordinatedURL in
      let originalIdentity = try validateTarget(coordinatedURL, requiresSingleLink: true)
      if let expectedHash {
        let input = try openTargetForReading(coordinatedURL)
        defer { try? input.close() }
        guard try ContentHash.sha256(of: input) == expectedHash else {
          throw CoordinatedFileError.preconditionFailed
        }
      }
      do {
        _ = try fileManager.replaceItemAt(
          coordinatedURL,
          withItemAt: stagedURL,
          backupItemName: nil,
          options: []
        )
      } catch {
        if currentIdentity(of: coordinatedURL) == originalIdentity {
          throw pathError(error, url: coordinatedURL)
        }
        removesReplacementDirectory = false
        throw commitFailure(
          error,
          targetURL: coordinatedURL,
          replacementDirectory: replacementDirectory
        )
      }
    }
  }

  private static func removeReplacementDirectory(_ directory: URL, stagedURL: URL) {
    // A failed replacement can copy a deny-delete ACL from the target to the staged file.
    if let emptyACL = acl_init(0) {
      _ = acl_set_link_np(stagedURL.path, ACL_TYPE_EXTENDED, emptyACL)
      acl_free(UnsafeMutableRawPointer(emptyACL))
    }
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      guard FileManager.default.fileExists(atPath: stagedURL.path) else { return }
      Diagnostics.write(
        code: "cleanup_failed",
        message: "staged replacement contents remain in \(directory.path)"
      )
    }
  }

  private static func copy(_ source: ReplacementSource, to destinationURL: URL) throws -> Int64 {
    let input: FileHandle
    let closesInput: Bool
    switch source {
    case .file(let sourceURL):
      let descriptor = open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
      guard descriptor >= 0 else {
        throw pathError(sourceURL, errno: errno)
      }
      input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      closesInput = true
    case .standardInput:
      input = .standardInput
      closesInput = false
    }
    defer {
      if closesInput {
        try? input.close()
      }
    }
    if case .file(let sourceURL) = source {
      var information = stat()
      guard fstat(input.fileDescriptor, &information) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      guard information.st_mode & S_IFMT == S_IFREG else {
        throw CoordinatedFileError.invalidSource("not a regular file: \(sourceURL.path)")
      }
      let flags = fcntl(input.fileDescriptor, F_GETFL)
      guard flags >= 0, fcntl(input.fileDescriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
    }
    let output = try FileHandle(forWritingTo: destinationURL)
    defer { try? output.close() }

    var byteCount: Int64 = 0
    while try autoreleasepool(invoking: {
      guard let data = try input.read(upToCount: bufferSize), !data.isEmpty else {
        return false
      }
      try output.write(contentsOf: data)
      byteCount += Int64(data.count)
      return true
    }) {
      continue
    }
    try output.synchronize()
    return byteCount
  }

  private static func validateTargetMetadata(
    _ url: URL,
    requiresSingleLink: Bool,
    timeout: TimeInterval
  ) throws {
    try coordinateReading(
      url,
      options: [.immediatelyAvailableMetadataOnly, .withoutChanges],
      timeout: timeout
    ) { coordinatedURL in
      var information = stat()
      guard lstat(coordinatedURL.path, &information) == 0 else { return }
      _ = try validateTarget(
        coordinatedURL,
        information: information,
        requiresSingleLink: requiresSingleLink
      )
    }
  }

  private static func validateTarget(
    _ url: URL,
    requiresSingleLink: Bool
  ) throws -> FileIdentity {
    var information = stat()
    guard lstat(url.path, &information) == 0 else {
      throw pathError(url, errno: errno)
    }
    return try validateTarget(
      url,
      information: information,
      requiresSingleLink: requiresSingleLink
    )
  }

  private static func validateTarget(
    _ url: URL,
    information: stat,
    requiresSingleLink: Bool
  ) throws -> FileIdentity {
    guard information.st_mode & S_IFMT == S_IFREG else {
      throw CoordinatedFileError.invalidTarget(url.path)
    }
    if requiresSingleLink, information.st_nlink != 1 {
      throw CoordinatedFileError.invalidTarget(url.path)
    }
    return FileIdentity(device: information.st_dev, inode: information.st_ino)
  }

  private static func currentIdentity(of url: URL) -> FileIdentity? {
    var information = stat()
    guard lstat(url.path, &information) == 0 else { return nil }
    return FileIdentity(device: information.st_dev, inode: information.st_ino)
  }

  private static func openTargetForReading(_ url: URL) throws -> FileHandle {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      if errno == ELOOP {
        throw CoordinatedFileError.invalidTarget(url.path)
      }
      throw pathError(url, errno: errno)
    }
    let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var information = stat()
    guard fstat(descriptor, &information) == 0 else {
      let errorNumber = errno
      try? input.close()
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
    }
    guard information.st_mode & S_IFMT == S_IFREG else {
      try? input.close()
      throw CoordinatedFileError.invalidTarget(url.path)
    }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
      let errorNumber = errno
      try? input.close()
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
    }
    return input
  }

  private static func pathError(_ url: URL, errno errorNumber: Int32) -> Error {
    switch errorNumber {
    case ENOENT, ENOTDIR:
      return CoordinatedFileError.notFound(url.path)
    case EACCES, EPERM:
      return CoordinatedFileError.permissionDenied(url.path)
    default:
      return NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
    }
  }

  private static func pathError(_ error: Error, url: URL) -> Error {
    let cocoaError = error as NSError
    if cocoaError.domain == NSPOSIXErrorDomain {
      return pathError(url, errno: Int32(cocoaError.code))
    }
    if let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain
    {
      return pathError(url, errno: Int32(underlying.code))
    }
    if cocoaError.domain == NSCocoaErrorDomain {
      switch CocoaError.Code(rawValue: cocoaError.code) {
      case .fileNoSuchFile, .fileReadNoSuchFile:
        return CoordinatedFileError.notFound(url.path)
      case .fileReadNoPermission, .fileWriteNoPermission:
        return CoordinatedFileError.permissionDenied(url.path)
      default:
        break
      }
    }
    return error
  }

  private static func commitFailure(
    _ error: Error,
    targetURL: URL,
    replacementDirectory: URL
  ) -> CoordinatedFileError {
    var message =
      "\(error.localizedDescription); replacement outcome is uncertain; inspect the target "
      + "before retrying (recovery directory: \(replacementDirectory.path))"
    let originalLocation = (error as NSError).userInfo["NSFileOriginalItemLocationKey"]
    let originalURL =
      (originalLocation as? URL)
      ?? (originalLocation as? NSURL).map { $0 as URL }
    if let originalURL,
      originalURL.standardizedFileURL != targetURL.standardizedFileURL
    {
      message += "; original item: \(originalURL.path)"
    }
    return .commitFailed(message)
  }

  private static func coordinateReading(
    _ url: URL,
    options: NSFileCoordinator.ReadingOptions = [],
    timeout: TimeInterval,
    operation: (URL) throws -> Void
  ) throws {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    let deadline = CoordinationDeadline(coordinator: coordinator, timeout: timeout)
    let timer = deadline.schedule()
    defer {
      timer.cancel()
      deadline.finish()
    }
    var coordinationError: NSError?
    var operationResult: Result<Void, Error>?

    coordinator.coordinate(
      readingItemAt: url,
      options: options,
      error: &coordinationError
    ) { coordinatedURL in
      guard deadline.beginAccessing() else { return }
      operationResult = Result {
        try operation(coordinatedURL)
      }
    }

    if deadline.didTimeOut {
      throw CoordinatedFileError.timedOut
    }
    if let operationResult {
      return try operationResult.get()
    }
    if let coordinationError {
      throw pathError(coordinationError, url: url)
    }
    throw CocoaError(.fileReadUnknown)
  }

  private static func coordinateWriting(
    _ url: URL,
    timeout: TimeInterval,
    operation: (URL) throws -> Void
  ) throws {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    let deadline = CoordinationDeadline(coordinator: coordinator, timeout: timeout)
    let timer = deadline.schedule()
    defer {
      timer.cancel()
      deadline.finish()
    }
    var coordinationError: NSError?
    var operationResult: Result<Void, Error>?

    coordinator.coordinate(
      writingItemAt: url,
      // Save presented edits before checking the precondition and replacing the contents.
      options: .forMerging,
      error: &coordinationError
    ) { coordinatedURL in
      guard deadline.beginAccessing() else { return }
      operationResult = Result {
        try operation(coordinatedURL)
      }
    }

    if deadline.didTimeOut {
      throw CoordinatedFileError.timedOut
    }
    if let operationResult {
      return try operationResult.get()
    }
    if let coordinationError {
      throw pathError(coordinationError, url: url)
    }
    throw CocoaError(.fileWriteUnknown)
  }
}

private final class CoordinationDeadline: @unchecked Sendable {
  private enum State {
    case waiting
    case accessing
    case timedOut
    case finished
  }

  private let coordinator: NSFileCoordinator
  private let lock = NSLock()
  private let timeout: TimeInterval
  private var state = State.waiting

  init(coordinator: NSFileCoordinator, timeout: TimeInterval) {
    self.coordinator = coordinator
    self.timeout = timeout
  }

  var didTimeOut: Bool {
    lock.withLock { state == .timedOut }
  }

  func schedule() -> DispatchWorkItem {
    let workItem = DispatchWorkItem { [weak self] in
      self?.timeOut()
    }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + timeout,
      execute: workItem
    )
    return workItem
  }

  func beginAccessing() -> Bool {
    lock.withLock {
      guard state == .waiting else { return false }
      state = .accessing
      return true
    }
  }

  func finish() {
    lock.withLock {
      if state != .timedOut {
        state = .finished
      }
    }
  }

  private func timeOut() {
    let shouldCancel = lock.withLock {
      guard state == .waiting else { return false }
      state = .timedOut
      return true
    }
    if shouldCancel {
      coordinator.cancel()
    }
  }
}
