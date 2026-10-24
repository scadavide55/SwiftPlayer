import Foundation
import Network
import Darwin

/// A small, dependency-free HTTP server that runs inside the app so media files
/// can be dropped onto the Apple TV from any browser on the same network.
///
/// Access is gated by a short PIN that is displayed on the TV (and embedded in
/// the QR code) so that other devices on the LAN cannot upload or delete files
/// without it. Uploads are streamed straight to the app's Documents directory,
/// where `LocalLibrary` picks them up automatically.
@MainActor
final class LocalFileServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var activePort: UInt16?
    @Published private(set) var localAddresses: [String] = []
    @Published private(set) var errorMessage: String?

    /// Short PIN required by the web page. Regenerated every time the server
    /// starts so a previously shared code cannot be reused indefinitely.
    @Published private(set) var accessToken = LocalFileServer.makeToken()

    let directory: URL

    private let queue = DispatchQueue(label: "com.davide.SwiftPlayerTV.upload-server")
    private let preferredPorts: [UInt16] = [8080, 8081, 8082, 8083, 8084]
    private var portIndex = 0
    private var listener: NWListener?

    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The address to open on another device, without the PIN.
    var serverURL: String? {
        guard let address = localAddresses.first, let port = activePort else { return nil }
        return "http://\(address):\(port)"
    }

    /// A convenience URL that authenticates automatically, used by the QR code.
    var authenticatedURL: String? {
        guard let serverURL else { return nil }
        return "\(serverURL)/?token=\(accessToken)"
    }

    func start() {
        guard listener == nil else { return }
        errorMessage = nil
        portIndex = 0
        accessToken = Self.makeToken()
        startListener()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        activePort = nil
        localAddresses = []
    }

    private func startListener() {
        let port = preferredPorts[min(portIndex, preferredPorts.count - 1)]
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(
                name: ProcessInfo.processInfo.hostName,
                type: "_swiftplayer._tcp"
            )
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handle(state: state) }
            }
            // Capture the immutable values the connection needs so the
            // background handler never touches main-actor state.
            let directory = directory
            let token = accessToken
            let queue = queue
            listener.newConnectionHandler = { connection in
                HTTPConnection(
                    connection: connection,
                    directory: directory,
                    token: token,
                    queue: queue
                ).start()
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            handleListenerFailure(error)
        }
    }

    private func handle(state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            activePort = listener?.port?.rawValue ?? preferredPorts[min(portIndex, preferredPorts.count - 1)]
            localAddresses = Self.localIPv4Addresses()
        case .failed(let error):
            handleListenerFailure(error)
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func handleListenerFailure(_ error: Error) {
        var addressInUse = false
        if let nwError = error as? NWError, case .posix(let code) = nwError, code == .EADDRINUSE {
            addressInUse = true
        }

        if addressInUse, portIndex + 1 < preferredPorts.count {
            portIndex += 1
            listener?.cancel()
            listener = nil
            startListener()
            return
        }

        errorMessage = error.localizedDescription
        isRunning = false
        activePort = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: - Helpers

    private static func makeToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else { return [] }
        defer { freeifaddrs(interfacePointer) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        address,
                        socklen_t(address.pointee.sa_len),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if result == 0, let value = String(validatingUTF8: host) {
                        addresses.append(value)
                    }
                }
            }
            pointer = interface.ifa_next
        }
        return addresses
    }
}

// MARK: - Request parsing

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let cookies: [String: String]

    init?(headerData: Data) {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        method = String(parts[0]).uppercased()

        let target = String(parts[1])
        if let components = URLComponents(string: "http://localhost\(target)") {
            path = components.path.isEmpty ? "/" : components.path
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
            self.query = query
        } else {
            path = target
            query = [:]
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        self.headers = headers

        var cookies: [String: String] = [:]
        for pair in (headers["cookie"] ?? "").components(separatedBy: ";") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            if pieces.count == 2 {
                cookies[String(pieces[0]).trimmingCharacters(in: .whitespaces)] =
                    String(pieces[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        self.cookies = cookies
    }
}

// MARK: - Connection handling

final class HTTPConnection {
    private let connection: NWConnection
    private let directory: URL
    private let token: String
    private let queue: DispatchQueue

    private var buffer = Data()
    private var request: HTTPRequest?
    private var parser: MultipartFormParser?

    private var expectedBodyBytes = 0
    private var receivedBodyBytes = 0
    private var bodyConsumer: ((Data) -> Void)?
    private var bodyCompletion: (() -> Void)?
    private var urlEncodedBody = Data()

    private var isFinished = false
    /// Retains the connection until its lifecycle ends.
    private var selfRetain: HTTPConnection?

    init(connection: NWConnection, directory: URL, token: String, queue: DispatchQueue) {
        self.connection = connection
        self.directory = directory
        self.token = token
        self.queue = queue
    }

    func start() {
        selfRetain = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }

            if self.isFinished { return }

            if error != nil || isComplete {
                self.finish()
                return
            }
            self.receive()
        }
    }

    private func processBuffer() {
        guard !isFinished else { return }

        if request == nil {
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 64 * 1024 {
                    respond(status: "431 Request Header Fields Too Large", body: Data())
                }
                return
            }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)

            guard let parsed = HTTPRequest(headerData: headerData) else {
                respond(status: "400 Bad Request", body: Data())
                return
            }
            request = parsed
            begin(parsed)
            if isFinished { return }
        }

        guard let bodyConsumer else { return }

        let chunk = buffer
        buffer.removeAll(keepingCapacity: true)
        bodyConsumer(chunk)
        receivedBodyBytes += chunk.count

        if receivedBodyBytes >= expectedBodyBytes {
            let completion = bodyCompletion
            self.bodyConsumer = nil
            self.bodyCompletion = nil
            completion?()
        }
    }

    // MARK: Routing

    private func begin(_ request: HTTPRequest) {
        switch (request.method, request.path) {
        case ("GET", "/"), ("HEAD", "/"):
            guard isAuthorized(request) else {
                if let supplied = request.query["token"], constantTimeEquals(supplied, token) {
                    respond(
                        status: "303 See Other",
                        headers: ["Location": "/", "Set-Cookie": cookieHeader],
                        body: Data()
                    )
                } else {
                    respond(
                        status: "200 OK",
                        headers: ["Content-Type": "text/html; charset=utf-8"],
                        body: Data(LocalFileServer.makeLoginPage(failed: request.query["error"] != nil).utf8)
                    )
                }
                return
            }
            let message = request.query["message"]
            let html = LocalFileServer.makeIndexPage(directory: directory, message: message)
            respond(status: "200 OK", headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))

        case ("POST", "/auth"):
            readURLEncodedBody { [weak self] fields in
                guard let self else { return }
                if constantTimeEquals(fields["pin"] ?? "", self.token) {
                    self.respond(
                        status: "303 See Other",
                        headers: ["Location": "/", "Set-Cookie": self.cookieHeader],
                        body: Data()
                    )
                } else {
                    self.respond(
                        status: "200 OK",
                        headers: ["Content-Type": "text/html; charset=utf-8"],
                        body: Data(LocalFileServer.makeLoginPage(failed: true).utf8)
                    )
                }
            }

        case ("POST", "/upload"):
            guard isAuthorized(request) else {
                respond(status: "401 Unauthorized", body: Data("Not authorized.".utf8))
                return
            }
            guard let contentType = request.headers["content-type"],
                  let boundary = MultipartFormParser.boundary(from: contentType) else {
                respond(status: "400 Bad Request", body: Data("Expected a multipart/form-data upload.".utf8))
                return
            }
            guard let length = contentLength(request) else {
                respond(status: "411 Length Required", body: Data("Missing Content-Length.".utf8))
                return
            }
            expectedBodyBytes = length
            receivedBodyBytes = 0
            let parser = MultipartFormParser(boundary: boundary, directory: directory)
            self.parser = parser
            bodyConsumer = { data in parser.consume(data) }
            bodyCompletion = { [weak self] in self?.completeUpload() }

        case ("POST", "/delete"):
            guard isAuthorized(request) else {
                respond(status: "401 Unauthorized", body: Data("Not authorized.".utf8))
                return
            }
            readURLEncodedBody { [weak self] fields in
                self?.deleteFile(named: fields["name"] ?? "")
            }

        default:
            respond(status: "404 Not Found", body: Data())
        }
    }

    private func completeUpload() {
        guard let parser else { return }
        parser.finish()
        let saved = parser.savedCount
        let skipped = parser.skippedCount
        let ranOutOfSpace = parser.ranOutOfSpace
        self.parser = nil
        parser.cleanup(removeFiles: false)

        var message: String
        if ranOutOfSpace {
            message = "Not enough free space. Some files were not uploaded."
        } else if saved == 0 && skipped > 0 {
            message = "No supported media files were found."
        } else if skipped > 0 {
            message = "Uploaded \(saved) file\(saved == 1 ? "" : "s"); skipped \(skipped) unsupported."
        } else {
            message = "Uploaded \(saved) file\(saved == 1 ? "" : "s")."
        }
        let encoded = LocalFileServer.encodeQueryValue(message)
        respond(status: "303 See Other", headers: ["Location": "/?message=\(encoded)"], body: Data())
    }

    private func readURLEncodedBody(maxBytes: Int = 8 * 1024, completion: @escaping ([String: String]) -> Void) {
        guard let length = contentLength(request), length <= maxBytes else {
            respond(status: "413 Payload Too Large", body: Data())
            return
        }
        expectedBodyBytes = length
        receivedBodyBytes = 0
        urlEncodedBody = Data()
        bodyConsumer = { [weak self] data in self?.urlEncodedBody.append(data) }
        bodyCompletion = { [weak self] in
            guard let self else { return }
            completion(Self.parseFormBody(self.urlEncodedBody))
        }
    }

    private func deleteFile(named rawName: String) {
        let name = (rawName as NSString).lastPathComponent
        guard !name.isEmpty,
              supportedExtensions.contains((name as NSString).pathExtension.lowercased()) else {
            respond(status: "400 Bad Request", body: Data())
            return
        }
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let message = LocalFileServer.encodeQueryValue("Deleted \(name).")
        respond(status: "303 See Other", headers: ["Location": "/?message=\(message)"], body: Data())
    }

    // MARK: Auth

    private var cookieHeader: String {
        "swiftplayer_auth=\(token); Path=/; HttpOnly; SameSite=Lax"
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        if let cookie = request.cookies["swiftplayer_auth"], constantTimeEquals(cookie, token) {
            return true
        }
        return false
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for index in a.indices {
            result |= a[index] ^ b[index]
        }
        return result == 0
    }

    private static func parseFormBody(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in text.components(separatedBy: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pieces.first,
                  let decodedKey = String(key).replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { continue }
            let rawValue = pieces.count > 1 ? String(pieces[1]) : ""
            let decodedValue = rawValue.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawValue
            result[decodedKey] = decodedValue
        }
        return result
    }

    private func contentLength(_ request: HTTPRequest?) -> Int? {
        guard let value = request?.headers["content-length"], let length = Int(value) else { return nil }
        return length
    }

    // MARK: Responding

    private func respond(status: String, headers: [String: String] = [:], body: Data) {
        guard !isFinished else { return }
        isFinished = true

        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "Cache-Control: no-store\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var payload = Data(response.utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func finish() {
        guard !isFinished else {
            selfRetain = nil
            return
        }
        isFinished = true
        // An aborted upload should not leave a half-written file behind.
        parser?.cleanup(removeFiles: true)
        parser = nil
        connection.cancel()
        selfRetain = nil
    }
}

// MARK: - Multipart form parsing

/// Streams a `multipart/form-data` body to disk, one file part at a time, so
/// multi-gigabyte uploads never have to be held in memory. Unsupported file
/// types are skipped, and running out of disk space aborts the transfer.
final class MultipartFormParser {
    private enum State {
        case headers
        case body
    }

    private let delimiter: Data
    private let directory: URL
    private var buffer: Data
    private var state: State = .headers

    private var fileHandle: FileHandle?
    private var currentFileURL: URL?
    private var currentFileWritten: Int64 = 0
    private var bytesSinceSpaceCheck: Int64 = 0

    private(set) var savedCount = 0
    private(set) var skippedCount = 0
    private(set) var didComplete = false
    private(set) var ranOutOfSpace = false

    /// Bytes above which we refuse to start writing a file.
    private static let minimumFreeSpace: Int64 = 200 * 1024 * 1024

    init(boundary: String, directory: URL) {
        self.directory = directory
        self.delimiter = Data("\r\n--\(boundary)".utf8)
        // Seed with a CRLF so the opening "--boundary" matches the delimiter.
        self.buffer = Data([0x0D, 0x0A])
    }

    static func boundary(from contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var value = String(contentType[range.upperBound...])
        if let separator = value.firstIndex(of: ";") {
            value = String(value[..<separator])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    func consume(_ data: Data) {
        buffer.append(data)
        process()
    }

    func finish() {
        if ranOutOfSpace, let currentFileURL {
            try? FileManager.default.removeItem(at: currentFileURL)
        }
        closeCurrentFile()
    }

    /// Closes the current file and optionally deletes everything written during
    /// this request. Used when a transfer is aborted by the client.
    func cleanup(removeFiles: Bool) {
        let pending = currentFileURL
        closeCurrentFile()
        if removeFiles {
            if let pending { try? FileManager.default.removeItem(at: pending) }
        }
    }

    private func process() {
        while true {
            switch state {
            case .headers:
                guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
                let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                beginPart(headerData: headerData)

            case .body:
                guard let boundaryRange = buffer.range(of: delimiter) else {
                    flushSafeBytes()
                    return
                }
                let fileBytes = buffer.subdata(in: buffer.startIndex..<boundaryRange.lowerBound)
                write(fileBytes)
                buffer.removeSubrange(buffer.startIndex..<boundaryRange.upperBound)

                if buffer.starts(with: Data("--".utf8)) {
                    buffer.removeAll()
                    closeCurrentFile()
                    didComplete = true
                    return
                }
                closeCurrentFile()
                state = .headers
            }
        }
    }

    private func beginPart(headerData: Data) {
        closeCurrentFile()

        guard let headers = String(data: headerData, encoding: .utf8),
              let filename = Self.filename(from: headers) else {
            // A non-file field such as a token; its body is skipped.
            state = .body
            return
        }

        let sanitized = Self.sanitize(filename)
        let ext = (sanitized as NSString).pathExtension.lowercased()

        guard supportedExtensions.contains(ext), Self.hasFreeSpace(at: directory) else {
            if !supportedExtensions.contains(ext) {
                skippedCount += 1
            } else {
                ranOutOfSpace = true
            }
            state = .body
            return
        }

        let destination = Self.uniqueURL(for: sanitized, in: directory)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: destination)
        currentFileURL = destination
        currentFileWritten = 0
        bytesSinceSpaceCheck = 0
        if fileHandle != nil {
            savedCount += 1
        }
        state = .body
    }

    private func write(_ data: Data) {
        guard !data.isEmpty, let fileHandle else { return }
        do {
            try fileHandle.write(contentsOf: data)
            currentFileWritten += Int64(data.count)
            bytesSinceSpaceCheck += Int64(data.count)

            // Re-check periodically so a huge upload can't silently fill the disk.
            if bytesSinceSpaceCheck >= 32 * 1024 * 1024 {
                bytesSinceSpaceCheck = 0
                if !Self.hasFreeSpace(at: directory) {
                    ranOutOfSpace = true
                }
            }
        } catch {
            ranOutOfSpace = true
        }
    }

    /// Writes everything except a trailing window that could still be the start
    /// of a boundary split across two network packets.
    private func flushSafeBytes() {
        let keep = delimiter.count - 1
        guard buffer.count > keep else { return }
        let flushCount = buffer.count - keep
        write(buffer.subdata(in: buffer.startIndex..<buffer.startIndex + flushCount))
        buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + flushCount)
    }

    private func closeCurrentFile() {
        if let fileHandle {
            try? fileHandle.close()
        }
        fileHandle = nil
        currentFileURL = nil
        currentFileWritten = 0
    }

    private static func hasFreeSpace(at directory: URL) -> Bool {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let available = values?.volumeAvailableCapacity else { return true }
        return Int64(available) > minimumFreeSpace
    }

    private static func filename(from headers: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("content-disposition:") else { continue }
            guard let equals = line.range(of: "filename=", options: .caseInsensitive) else { continue }

            var value = String(line[equals.upperBound...])
            if let separator = value.firstIndex(of: ";") {
                value = String(value[..<separator])
            }
            value = value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func sanitize(_ filename: String) -> String {
        let base = (filename as NSString).lastPathComponent
        let cleaned = base
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "upload" : cleaned
    }

    private static func uniqueURL(for filename: String, in directory: URL) -> URL {
        let manager = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var index = 1

        while manager.fileExists(atPath: candidate.path) {
            let name = "\(base) (\(index))"
            candidate = ext.isEmpty
                ? directory.appendingPathComponent(name)
                : directory.appendingPathComponent(name).appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}

// MARK: - Web pages

extension LocalFileServer {
    fileprivate nonisolated static func makeLoginPage(failed: Bool) -> String {
        let errorBlock = failed
            ? #"<p class="error">Incorrect PIN. Try again.</p>"#
            : ""
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>SwiftPlayer</title>
        <style>
            :root { color-scheme: dark; }
            * { box-sizing: border-box; }
            body {
                margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                background: #0b0b0f; color: #f2f2f7; padding: 24px;
            }
            main { width: 100%; max-width: 360px; text-align: center; }
            h1 { font-size: 26px; margin: 0 0 6px; }
            p.subtitle { color: #8e8e93; margin: 0 0 28px; }
            input {
                width: 100%; padding: 16px; font-size: 24px; text-align: center; letter-spacing: 8px;
                text-transform: uppercase; border-radius: 12px; border: 1px solid #3a3a3c;
                background: #16161a; color: #fff; margin-bottom: 14px;
            }
            button {
                width: 100%; padding: 15px; font-size: 17px; font-weight: 600; border: 0;
                border-radius: 12px; background: #0a84ff; color: white; cursor: pointer;
            }
            button:hover { background: #0070e0; }
            .error { color: #ff453a; margin: 0 0 16px; }
            .hint { color: #8e8e93; font-size: 13px; margin-top: 18px; }
        </style>
        </head>
        <body>
        <main>
            <h1>SwiftPlayer</h1>
            <p class="subtitle">Enter the PIN shown on your Apple TV</p>
            \(errorBlock)
            <form method="post" action="/auth">
                <input name="pin" inputmode="text" autocomplete="one-time-code" autofocus maxlength="6" placeholder="PIN">
                <button type="submit">Open</button>
            </form>
            <p class="hint">Tip: scan the QR code on the TV to skip this step.</p>
        </main>
        </body>
        </html>
        """
    }

    fileprivate nonisolated static func makeIndexPage(directory: URL, message: String?) -> String {
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        let files = contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let rows: String
        if files.isEmpty {
            rows = #"<li class="empty">No files yet — drop some above.</li>"#
        } else {
            rows = files.map { url -> String in
                let name = escapeHTML(url.lastPathComponent)
                let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                let encoded = encodeQueryValue(url.lastPathComponent)
                return """
                <li>
                    <div class="meta">
                        <span class="name">\(name)</span>
                        <span class="size">\(size)</span>
                    </div>
                    <form method="post" action="/delete" onsubmit="return confirm('Delete this file?');">
                        <input type="hidden" name="name" value="\(encoded)">
                        <button class="delete" type="submit">Delete</button>
                    </form>
                </li>
                """
            }.joined(separator: "\n")
        }

        let totalBytes = files.reduce(Int64(0)) { partial, url in
            partial + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        let summary = "\(files.count) file\(files.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        let banner = message.map { #"<p class="banner">\#(escapeHTML($0))</p>"# } ?? ""

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>SwiftPlayer Upload</title>
        <style>
            :root { color-scheme: dark; }
            * { box-sizing: border-box; }
            body {
                margin: 0; min-height: 100vh;
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                background: #0b0b0f; color: #f2f2f7;
                display: flex; justify-content: center; padding: 48px 20px;
            }
            main { width: 100%; max-width: 640px; }
            h1 { font-size: 28px; margin: 0 0 4px; }
            .subtitle { color: #8e8e93; margin: 0 0 24px; }
            .banner {
                background: #10233b; border: 1px solid #0a84ff55; color: #cfe4ff;
                padding: 12px 16px; border-radius: 12px; margin: 0 0 20px; font-size: 14px;
            }
            #dropzone {
                border: 2px dashed #3a3a3c; border-radius: 16px; padding: 44px 20px;
                text-align: center; background: #16161a; cursor: pointer;
                transition: border-color .15s ease, background .15s ease;
            }
            #dropzone.over { border-color: #0a84ff; background: #101826; }
            #dropzone strong { color: #0a84ff; }
            #dropzone p { margin: 12px 0 0; color: #8e8e93; font-size: 14px; }
            .track { height: 6px; margin-top: 16px; border-radius: 3px; background: #1f1f24; overflow: hidden; }
            #progress { height: 6px; width: 0%; border-radius: 3px; background: #0a84ff; transition: width .1s linear; }
            .summary { margin: 32px 0 12px; color: #8e8e93; font-size: 13px; text-transform: uppercase; letter-spacing: .06em; }
            ul { list-style: none; margin: 0; padding: 0; }
            li {
                display: flex; align-items: center; justify-content: space-between; gap: 16px;
                padding: 14px 16px; background: #16161a; border-radius: 12px; margin-bottom: 8px;
            }
            li.empty { justify-content: center; color: #8e8e93; }
            .meta { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
            .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .size { color: #8e8e93; font-size: 12px; }
            form { margin: 0; }
            .delete {
                color: #ff453a; background: none; border: 0; font-size: 14px; cursor: pointer;
                flex-shrink: 0; padding: 6px 8px;
            }
            .delete:hover { text-decoration: underline; }
        </style>
        </head>
        <body>
        <main>
            <h1>SwiftPlayer</h1>
            <p class="subtitle">Send media to your Apple TV</p>
            \(banner)

            <label id="dropzone" for="file">
                <div><strong>Choose files</strong> or drop them here</div>
                <p>MP4, MOV, M4V, MP3, M4A, AAC, WAV, AIFF, CAF</p>
                <div class="track"><div id="progress"></div></div>
            </label>
            <input id="file" type="file" multiple accept="video/*,audio/*" style="display:none">

            <p class="summary">\(summary)</p>
            <ul>
        \(rows)
            </ul>
        </main>
        <script>
            const dropzone = document.getElementById('dropzone');
            const input = document.getElementById('file');
            const progress = document.getElementById('progress');

            ['dragenter', 'dragover'].forEach(function (name) {
                dropzone.addEventListener(name, function (event) {
                    event.preventDefault();
                    dropzone.classList.add('over');
                });
            });
            ['dragleave', 'drop'].forEach(function (name) {
                dropzone.addEventListener(name, function (event) {
                    event.preventDefault();
                    dropzone.classList.remove('over');
                });
            });
            dropzone.addEventListener('drop', function (event) {
                upload(event.dataTransfer.files);
            });
            input.addEventListener('change', function () {
                upload(input.files);
            });

            function upload(files) {
                if (!files || files.length === 0) { return; }
                const form = new FormData();
                for (const file of files) { form.append('file', file); }

                const request = new XMLHttpRequest();
                request.open('POST', '/upload');
                request.upload.onprogress = function (event) {
                    if (event.lengthComputable) {
                        progress.style.width = (event.loaded / event.total * 100) + '%';
                    }
                };
                request.onload = function () { window.location.reload(); };
                request.onerror = function () { alert('Upload failed. Please try again.'); };
                request.send(form);
            }
        </script>
        </body>
        </html>
        """
    }

    nonisolated static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    nonisolated static func encodeQueryValue(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
