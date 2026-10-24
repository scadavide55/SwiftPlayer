import Testing
import Foundation
@testable import SwiftPlayerTV

@Suite("Multipart form parsing")
struct MultipartFormParserTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBody(boundary: String, parts: [(filename: String?, content: Data)]) -> Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            if let filename = part.filename {
                body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
                body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
            } else {
                body.append(Data("Content-Disposition: form-data; name=\"field\"\r\n\r\n".utf8))
            }
            body.append(part.content)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private func feed(_ parser: MultipartFormParser, _ data: Data, chunkSizes: [Int]) {
        var index = data.startIndex
        var i = 0
        while index < data.endIndex {
            let size = min(chunkSizes[i % chunkSizes.count], data.distance(from: index, to: data.endIndex))
            let end = data.index(index, offsetBy: size)
            parser.consume(data.subdata(in: index..<end))
            index = end
            i += 1
        }
    }

    @Test func writesFileExactlyAcrossChunkBoundaries() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let boundary = "----testboundary"
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        let body = makeBody(boundary: boundary, parts: [(filename: "video.mp4", content: payload)])

        let parser = MultipartFormParser(boundary: boundary, directory: dir)
        feed(parser, body, chunkSizes: [1, 2, 7, 64, 1024, 3])
        parser.finish()

        let saved = try Data(contentsOf: dir.appendingPathComponent("video.mp4"))
        #expect(parser.savedCount == 1)
        #expect(parser.didComplete)
        #expect(saved == payload)
    }

    @Test func ignoresNonFileFields() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let boundary = "----b"
        let body = makeBody(boundary: boundary, parts: [
            (filename: nil, content: Data("just a field".utf8)),
            (filename: "clip.mov", content: Data("movie".utf8))
        ])

        let parser = MultipartFormParser(boundary: boundary, directory: dir)
        parser.consume(body)
        parser.finish()

        #expect(parser.savedCount == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("clip.mov").path))
    }

    @Test func skipsUnsupportedFiles() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let boundary = "----b"
        let body = makeBody(boundary: boundary, parts: [
            (filename: "notes.txt", content: Data("hello".utf8)),
            (filename: "song.mp3", content: Data("abc".utf8))
        ])

        let parser = MultipartFormParser(boundary: boundary, directory: dir)
        parser.consume(body)
        parser.finish()

        #expect(parser.savedCount == 1)
        #expect(parser.skippedCount == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("song.mp3").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.txt").path))
    }

    @Test func cleanupRemovesPartialFile() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let boundary = "----b"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"partial.mp4\"\r\n\r\n".utf8)
        body.append(Data(repeating: 0x41, count: 4096))

        let parser = MultipartFormParser(boundary: boundary, directory: dir)
        parser.consume(body)

        let partial = dir.appendingPathComponent("partial.mp4")
        #expect(FileManager.default.fileExists(atPath: partial.path))
        parser.cleanup(removeFiles: true)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func uniquesDuplicateFilenames() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let boundary = "----b"
        let body = makeBody(boundary: boundary, parts: [
            (filename: "same.mp4", content: Data("one".utf8)),
            (filename: "same.mp4", content: Data("two".utf8))
        ])

        let parser = MultipartFormParser(boundary: boundary, directory: dir)
        parser.consume(body)
        parser.finish()

        let saved = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
        #expect(saved == ["same (1).mp4", "same.mp4"])
    }

    @Test func sanitizesPathTraversalFilenames() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let boundary = "----b"
        let body = makeBody(boundary: boundary, parts: [(filename: "../evil.mp4", content: Data("x".utf8))])

        let parser = MultipartFormParser(boundary: boundary, directory: dir)
        parser.consume(body)
        parser.finish()

        let saved = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(saved.count == 1)
        #expect(saved.first?.lastPathComponent == "evil.mp4")
    }

    @Test func extractsBoundaries() {
        #expect(MultipartFormParser.boundary(from: "multipart/form-data; boundary=\"abc123\"") == "abc123")
        #expect(MultipartFormParser.boundary(from: "multipart/form-data; boundary=xyz") == "xyz")
        #expect(MultipartFormParser.boundary(from: "text/plain") == nil)
    }
}

@Suite("HTTP request parsing")
struct HTTPRequestTests {
    @Test func parsesRequestLineQueryHeadersAndCookies() throws {
        let raw = "GET /delete?name=My%20Video.mp4 HTTP/1.1\r\nHost: localhost\r\nCookie: a=1; swiftplayer_auth=ABC123\r\n\r\n"
        let request = try #require(HTTPRequest(headerData: Data(raw.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/delete")
        #expect(request.query["name"] == "My Video.mp4")
        #expect(request.headers["host"] == "localhost")
        #expect(request.cookies["swiftplayer_auth"] == "ABC123")
        #expect(request.cookies["a"] == "1")
    }

    @Test func parsesUploadHeaders() throws {
        let raw = "POST /upload HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=\"q\"\r\nContent-Length: 10\r\n\r\n"
        let request = try #require(HTTPRequest(headerData: Data(raw.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/upload")
        #expect(request.headers["content-length"] == "10")
        #expect(MultipartFormParser.boundary(from: request.headers["content-type"] ?? "") == "q")
    }

    @Test func defaultsToRootPath() throws {
        let raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let request = try #require(HTTPRequest(headerData: Data(raw.utf8)))
        #expect(request.path == "/")
    }

    @Test func rejectsMalformedRequest() {
        #expect(HTTPRequest(headerData: Data("nonsense".utf8)) == nil)
    }
}
