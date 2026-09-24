import Foundation

enum Diagnostics {
  static func write(code: String, message: String) {
    let line = "filecoord: \(code): \(message)\n"
    try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
  }
}
