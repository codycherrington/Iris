import Foundation

/// Reassembles newline-delimited text from arbitrary byte chunks.
///
/// A pipe hands us whatever happened to be available, so a single JSON event routinely
/// arrives split across two reads — and a single read routinely contains several events.
/// Getting this wrong produces truncated JSON that looks like protocol drift, so it is
/// deliberately separated from the process plumbing and tested on its own.
///
/// Thread-safe: the readability handler is serial, but the buffer outlives any one call,
/// so access is locked rather than assumed.
final class LineAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    private static let newline = UInt8(0x0A)

    /// Append a chunk and return every *complete* line it finished.
    /// A trailing partial line stays buffered for the next chunk.
    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(chunk)
        guard buffer.contains(Self.newline) else { return [] }

        var lines: [String] = []
        var searchStart = buffer.startIndex

        while let newlineIndex = buffer[searchStart...].firstIndex(of: Self.newline) {
            let lineBytes = buffer[searchStart..<newlineIndex]
            if !lineBytes.isEmpty, let line = String(data: Data(lineBytes), encoding: .utf8) {
                lines.append(line)
            }
            searchStart = buffer.index(after: newlineIndex)
        }

        // Re-base the buffer so indices stay sane; Data slices keep their parent's indices.
        buffer = searchStart < buffer.endIndex ? Data(buffer[searchStart...]) : Data()
        return lines
    }

    /// Return any trailing bytes not terminated by a newline. Call at EOF — a process can
    /// exit having written a final line without its newline.
    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        let remainder = String(data: buffer, encoding: .utf8)
        buffer = Data()
        return remainder?.isEmpty == false ? remainder : nil
    }
}
