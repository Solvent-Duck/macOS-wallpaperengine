import Foundation

/// Parses Wallpaper Engine `.pkg` archive files.
///
/// ## File Format
///
/// WE `.pkg` files are simple flat archives:
///
/// ```
/// Header:
///   uint32  header_string_length
///   bytes   "PKGV" (header magic)
///
/// File Table:
///   uint32  file_count
///   For each file:
///     uint32  filename_length
///     bytes   filename (UTF-8)
///     uint32  offset (relative to data section start)
///     uint32  length
///
/// Data Section:
///   Raw file contents (offsets in file table are relative to here)
/// ```
///
/// The parser extracts all files to a temporary directory so they can be
/// loaded by the wallpaper renderers using standard file URLs.
struct PackageParser {

    /// Extract a `.pkg` archive to a temporary directory.
    ///
    /// - Parameter pkgURL: Path to the `.pkg` file.
    /// - Returns: URL of the directory containing extracted files.
    /// - Throws: `PackageError` if the file is corrupt or unreadable.
    static func extract(pkgURL: URL) throws -> URL {
        let data = try Data(contentsOf: pkgURL)
        let entries = try parseFileTable(data: data)

        // Create a temp directory for extraction
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperEngine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        print("[PackageParser] Extracting \(entries.files.count) files to \(tempDir.path)")

        for entry in entries.files {
            let fileURL = tempDir.appendingPathComponent(entry.filename)

            // Create subdirectories if the filename contains path separators
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let start = entries.dataOffset + entry.offset
            let end = start + entry.length
            guard end <= data.count else {
                throw PackageError.truncatedFile(entry.filename)
            }

            let fileData = data[start..<end]
            try fileData.write(to: fileURL)
        }

        print("[PackageParser] Extraction complete")
        return tempDir
    }

    // MARK: - Private

    private struct FileEntry {
        let filename: String
        let offset: Int
        let length: Int
    }

    private struct FileTable {
        let files: [FileEntry]
        let dataOffset: Int
    }

    private static func parseFileTable(data: Data) throws -> FileTable {
        var cursor = 0

        // Read and validate header magic
        let headerString = try readSizedString(data: data, cursor: &cursor)
        guard headerString == "PKGV" else {
            throw PackageError.invalidMagic(headerString)
        }

        // Read file count
        let fileCount = try readUInt32(data: data, cursor: &cursor)

        // Read file entries
        var entries: [FileEntry] = []
        entries.reserveCapacity(Int(fileCount))

        for _ in 0..<fileCount {
            let filename = try readSizedString(data: data, cursor: &cursor)
            let offset = try readUInt32(data: data, cursor: &cursor)
            let length = try readUInt32(data: data, cursor: &cursor)

            entries.append(FileEntry(
                filename: filename,
                offset: Int(offset),
                length: Int(length)
            ))
        }

        // The data section starts immediately after the file table
        let dataOffset = cursor

        return FileTable(files: entries, dataOffset: dataOffset)
    }

    private static func readUInt32(data: Data, cursor: inout Int) throws -> UInt32 {
        guard cursor + 4 <= data.count else {
            throw PackageError.unexpectedEOF
        }
        let value = data[cursor..<cursor+4].withUnsafeBytes { $0.load(as: UInt32.self) }
        cursor += 4
        return UInt32(littleEndian: value)
    }

    private static func readSizedString(data: Data, cursor: inout Int) throws -> String {
        let length = try readUInt32(data: data, cursor: &cursor)
        guard cursor + Int(length) <= data.count else {
            throw PackageError.unexpectedEOF
        }
        let stringData = data[cursor..<cursor+Int(length)]
        cursor += Int(length)

        guard let string = String(data: stringData, encoding: .utf8) else {
            throw PackageError.invalidString
        }
        return string
    }
}

enum PackageError: LocalizedError {
    case invalidMagic(String)
    case unexpectedEOF
    case invalidString
    case truncatedFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidMagic(let got):
            return "Invalid .pkg file: expected PKGV header, got \"\(got)\""
        case .unexpectedEOF:
            return "Unexpected end of .pkg file"
        case .invalidString:
            return "Invalid string encoding in .pkg file"
        case .truncatedFile(let name):
            return "File data truncated in .pkg archive: \(name)"
        }
    }
}
