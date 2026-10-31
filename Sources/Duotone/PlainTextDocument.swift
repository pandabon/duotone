import SwiftUI
import UniformTypeIdentifiers

struct PlainTextDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.plainText]

  var text: String

  init(text: String) { self.text = text }

  init(configuration: ReadConfiguration) throws {
    text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}
