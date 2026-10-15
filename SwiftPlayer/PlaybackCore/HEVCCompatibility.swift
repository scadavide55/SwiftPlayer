import Foundation
import Darwin

/// Retags self-contained HEVC sample descriptions for Apple's native decoder.
/// Only movie metadata changes; compressed frames, offsets and audio stay intact.
struct PreparedMedia: Sendable {
    let url: URL
    let temporaryDirectory: URL?

    nonisolated func removeTemporaryFiles() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }
}

enum HEVCCompatibility {
    nonisolated static func prepare(url: URL, allowClone: Bool = true) throws -> PreparedMedia {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        guard url.isFileURL, ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else {
            return PreparedMedia(url: url, temporaryDirectory: nil)
        }

        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        let length = try source.seekToEnd()
        var offset: UInt64 = 0
        var patches: [UInt64] = []
        while offset < length {
            try Task.checkCancellation()
            // Foundation may retain read buffers until this worker finishes.
            // Drain each box's buffers even when a file contains many tiny boxes.
            let size: UInt64? = try autoreleasepool {
                try source.seek(toOffset: offset)
                let header = try source.read(upToCount: 16) ?? Data()
                guard let box = box(in: header, at: 0, limit: length - offset) else { return nil }
                if box.type == "moov" {
                    // Bound metadata allocation, even for corrupt/untrusted files.
                    guard box.size <= 64 * 1024 * 1024 else { return nil }
                    try source.seek(toOffset: offset)
                    let data = try source.read(upToCount: Int(box.size)) ?? Data()
                    guard data.count == Int(box.size) else { return nil }
                    patches += sampleEntryOffsets(in: data).map { offset + UInt64($0) }
                }
                return box.size
            }
            guard let size else { break }
            offset += size
        }
        guard !patches.isEmpty else { return PreparedMedia(url: url, temporaryDirectory: nil) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftPlayer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        do {
            // APFS clones share storage with the source, making large 8K files cheap.
            // Other volumes fall back to a regular copy on this background worker.
            let cloned = allowClone && url.withUnsafeFileSystemRepresentation { sourcePath in
                destination.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else { return false }
                    return clonefile(sourcePath, destinationPath, 0) == 0
                }
            }
            if cloned {
                // A clone inherits source permissions, which may be read-only.
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } else {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let copy = try FileHandle(forWritingTo: destination)
                defer { try? copy.close() }
                try source.seek(toOffset: 0)
                while true {
                    try Task.checkCancellation()
                    // Keep fallback-copy memory bounded and cancellation responsive
                    // when the source is a multi-gigabyte file on another volume.
                    let reachedEnd = try autoreleasepool {
                        // Foundation can autorelease read buffers until this worker
                        // finishes. Drain them per chunk instead of per entire file.
                        let chunk = try source.read(upToCount: 4 * 1024 * 1024) ?? Data()
                        if chunk.isEmpty { return true }
                        try copy.write(contentsOf: chunk)
                        return false
                    }
                    if reachedEnd { break }
                }
            }
            try Task.checkCancellation()
            let output = try FileHandle(forUpdating: destination)
            defer { try? output.close() }
            guard try output.seekToEnd() == length else { throw CocoaError(.fileReadCorruptFile) }
            for patch in patches {
                try output.seek(toOffset: patch)
                guard try output.read(upToCount: 4) == Data("hev1".utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try output.seek(toOffset: patch)
                try output.write(contentsOf: Data("hvc1".utf8))
            }
            try Task.checkCancellation()
            return PreparedMedia(url: destination, temporaryDirectory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private struct Box {
        let type: String
        let size: UInt64
        let headerSize: Int
    }

    nonisolated private static func integer(_ data: Data, at offset: Int, bytes: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count, bytes <= data.count - offset else { return nil }
        return data[offset..<(offset + bytes)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    nonisolated private static func box(in data: Data, at offset: Int, limit: UInt64) -> Box? {
        guard limit >= 8, let shortSize = integer(data, at: offset, bytes: 4),
              offset <= data.count - 8 else { return nil }
        let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
        let headerSize = shortSize == 1 ? 16 : 8
        let size: UInt64
        if shortSize == 1 {
            guard let extended = integer(data, at: offset + 8, bytes: 8) else { return nil }
            size = extended
        } else {
            size = shortSize == 0 ? limit : shortSize
        }
        guard size >= UInt64(headerSize), size <= limit else { return nil }
        return Box(type: type, size: size, headerSize: headerSize)
    }

    /// Walk only the video sample table, never arbitrary occurrences in frame data.
    nonisolated static func sampleEntryOffsets(in movie: Data) -> [Int] {
        var result: [Int] = []
        func walk(_ start: Int, _ end: Int, depth: Int) {
            let path = ["moov", "trak", "mdia", "minf", "stbl", "stsd"]
            guard depth < path.count else { return }
            var offset = start
            while offset < end {
                guard let atom = box(in: movie, at: offset, limit: UInt64(end - offset)) else { return }
                let atomEnd = offset + Int(atom.size)
                if atom.type == path[depth] {
                    let payload = offset + atom.headerSize
                    if atom.type == "stsd" {
                        guard payload <= atomEnd - 8,
                              let count = integer(movie, at: payload + 4, bytes: 4) else { return }
                        var entry = payload + 8
                        for _ in 0..<count {
                            guard let sample = box(in: movie, at: entry, limit: UInt64(atomEnd - entry)) else { return }
                            let sampleEnd = entry + Int(sample.size)
                            if sample.type == "hev1",
                               hasParameterSets(movie, start: entry + sample.headerSize + 78, end: sampleEnd) {
                                result.append(entry + 4)
                            }
                            entry = sampleEnd
                        }
                    } else {
                        walk(payload, atomEnd, depth: depth + 1)
                    }
                }
                offset = atomEnd
            }
        }
        walk(0, movie.count, depth: 0)
        return result
    }

    /// hvc1 needs VPS/SPS/PPS in hvcC. Leave in-band-only streams untouched.
    nonisolated private static func hasParameterSets(_ data: Data, start: Int, end: Int) -> Bool {
        var offset = start
        while offset < end {
            guard let atom = box(in: data, at: offset, limit: UInt64(end - offset)) else { return false }
            let atomEnd = offset + Int(atom.size)
            if atom.type == "hvcC" {
                let config = offset + atom.headerSize
                guard config <= atomEnd - 23, data[config] == 1 else { return false }
                var cursor = config + 23
                var types: Set<UInt8> = []
                for _ in 0..<Int(data[config + 22]) {
                    guard cursor <= atomEnd - 3,
                          let count = integer(data, at: cursor + 1, bytes: 2) else { return false }
                    let type = data[cursor] & 0x3f
                    cursor += 3
                    for _ in 0..<count {
                        guard cursor <= atomEnd - 2,
                              let length = integer(data, at: cursor, bytes: 2), length > 0 else { return false }
                        cursor += 2
                        guard length <= UInt64(atomEnd - cursor) else { return false }
                        cursor += Int(length)
                    }
                    if count > 0 { types.insert(type) }
                }
                return types.isSuperset(of: [32, 33, 34])
            }
            offset = atomEnd
        }
        return false
    }
}
