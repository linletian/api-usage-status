import Foundation

extension FileManager {
    /// Atomically writes data to a URL by first writing to a temp file then renaming.
    /// This prevents file corruption from crashes during write.
    func atomicWrite(data: Data, to url: URL) throws {
        let tempURL = url.deletingPathExtension()
            .appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        try replaceItemAt(url, withItemAt: tempURL)
    }
}