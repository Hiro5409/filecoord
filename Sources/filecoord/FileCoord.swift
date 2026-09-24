import ArgumentParser
import Foundation

@main
struct FileCoord: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "filecoord",
    abstract: "Read and replace iCloud Drive files from scripts and AI agents.",
    discussion: """
      Runtime diagnostics use 'filecoord: CODE: MESSAGE' on standard error.
      Exit statuses are 0 for success, 1 for an operational failure, 3 for a stale precondition, 64 for invalid usage, and 124 for an access timeout.
      """,
    version: "0.1.0",
    subcommands: [Read.self, Replace.self]
  )
}

struct Replace: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Replace a file's contents from a completed input.",
    discussion: """
      Success writes nothing.
      A commit_failed diagnostic means the replacement outcome is uncertain and reports retained recovery data; inspect the target before retrying.
      A cleanup_failed diagnostic supplements the primary failure and identifies staged contents that could not be removed; the primary failure determines the exit status.
      """
  )

  @Argument(help: "The existing file to replace.")
  var path: String

  @Option(name: .long, help: "A local input file, or '-' for standard input.")
  var from: String

  @Option(name: .customLong("if-match"), help: "Replace only if the current SHA-256 matches.")
  var ifMatch: String?

  @Option(help: "Seconds to wait for each coordinated access.")
  var timeout: Double = 120

  func validate() throws {
    if let ifMatch, ContentHash.normalized(ifMatch) == nil {
      throw ValidationError("'--if-match' must be 'sha256:' followed by 64 hexadecimal digits.")
    }
    guard timeout.isFinite, timeout > 0 else {
      throw ValidationError("'--timeout' must be a positive finite number.")
    }
  }

  func run() throws {
    do {
      let source: ReplacementSource =
        from == "-"
        ? .standardInput
        : .file(URL(fileURLWithPath: from).standardizedFileURL)
      try CoordinatedFile.replace(
        URL(fileURLWithPath: path).standardizedFileURL,
        from: source,
        ifMatch: ifMatch.flatMap(ContentHash.normalized),
        timeout: timeout
      )
    } catch CoordinatedFileError.preconditionFailed {
      Diagnostics.write(
        code: "precondition_failed",
        message: "target contents do not match '--if-match'"
      )
      throw ExitCode(3)
    } catch CoordinatedFileError.timedOut {
      Diagnostics.write(code: "timed_out", message: "coordinated access timed out")
      throw ExitCode(124)
    } catch let error as CoordinatedFileError {
      Diagnostics.write(code: error.code, message: error.localizedDescription)
      throw ExitCode.failure
    } catch {
      Diagnostics.write(code: "replace_failed", message: error.localizedDescription)
      throw ExitCode.failure
    }
  }
}

struct Read: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Write a file's exact contents to standard output.",
    discussion: """
      A nonzero exit may leave partial bytes on standard output. Discard them.
      """
  )

  @Argument(help: "The existing file to read.")
  var path: String

  @Option(help: "Seconds to wait for coordinated access.")
  var timeout: Double = 120

  func validate() throws {
    guard timeout.isFinite, timeout > 0 else {
      throw ValidationError("'--timeout' must be a positive finite number.")
    }
  }

  func run() throws {
    do {
      try CoordinatedFile.read(
        URL(fileURLWithPath: path).standardizedFileURL,
        to: .standardOutput,
        timeout: timeout
      )
    } catch CoordinatedFileError.timedOut {
      Diagnostics.write(code: "timed_out", message: "coordinated access timed out")
      throw ExitCode(124)
    } catch let error as CoordinatedFileError {
      Diagnostics.write(code: error.code, message: error.localizedDescription)
      throw ExitCode.failure
    } catch {
      Diagnostics.write(code: "read_failed", message: error.localizedDescription)
      throw ExitCode.failure
    }
  }
}
