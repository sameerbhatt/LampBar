import CommonCrypto
import CryptoKit
import Darwin
import Foundation

enum MiIOError: LocalizedError {
    case invalidToken
    case invalidHost
    case socket(String)
    case timeout
    case badResponse
    case device(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidToken: return "Token must be 32 hex characters."
        case .invalidHost: return "Invalid lamp IP address."
        case .socket(let msg): return "Network error: \(msg)"
        case .timeout: return "Lamp did not respond (check IP / token)."
        case .badResponse: return "Unexpected response from lamp (token may be wrong)."
        case .device(let code, let message): return "Lamp error \(code): \(message)"
        }
    }
}

/// Minimal client for Xiaomi's encrypted miIO LAN protocol (UDP 54321).
///
/// Packet: 32-byte header (magic 0x2131, length, unknown, device id, stamp, md5 checksum)
/// followed by AES-128-CBC(JSON), with key = md5(token) and iv = md5(key + token).
final class MiIOClient: @unchecked Sendable {
    let host: String
    private let token: Data
    private let key: Data
    private let iv: Data
    private let queue = DispatchQueue(label: "lampbar.miio")
    private let port: UInt16 = 54321

    // Handshake state, only touched on `queue`.
    private var deviceID: UInt32?
    private var deviceStamp: UInt32 = 0
    private var stampTakenAt = Date()
    private var nextID = Int.random(in: 1...9000)

    init(host: String, tokenHex: String) throws {
        guard let token = Data(hex: tokenHex), token.count == 16 else { throw MiIOError.invalidToken }
        self.host = host
        self.token = token
        key = Data(Insecure.MD5.hash(data: token))
        iv = Data(Insecure.MD5.hash(data: key + token))
    }

    /// Sends a command and returns the decoded `result` field.
    func call(_ method: String, _ params: Any = [Any]()) async throws -> Any {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: try self.callSync(method, params))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Forces a fresh handshake on the next call (e.g. after the Mac wakes and the stamp is stale).
    func resetSession() {
        queue.async { self.deviceID = nil }
    }

    // MARK: - Synchronous internals (run on `queue`)

    private func callSync(_ method: String, _ params: Any) throws -> Any {
        var lastError: Error = MiIOError.timeout
        for attempt in 0..<3 {
            do {
                if deviceID == nil || attempt > 0 { try handshake() }
                return try exchange(method, params)
            } catch let error as MiIOError {
                if case .device = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private func handshake() throws {
        let hello = Data([0x21, 0x31, 0x00, 0x20]) + Data(repeating: 0xFF, count: 28)
        let reply = try roundTrip(hello) { $0.count >= 32 }
        deviceID = reply.readUInt32(at: 8)
        deviceStamp = reply.readUInt32(at: 12)
        stampTakenAt = Date()
    }

    private func exchange(_ method: String, _ params: Any) throws -> Any {
        guard let deviceID else { throw MiIOError.badResponse }
        nextID = nextID >= 9999 ? 1 : nextID + 1
        let id = nextID
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let encrypted = try aes(body, operation: CCOperation(kCCEncrypt))

        let stamp = deviceStamp &+ UInt32(max(0, Date().timeIntervalSince(stampTakenAt)) + 1)
        var packet = Data()
        packet.appendUInt16(0x2131)
        packet.appendUInt16(UInt16(32 + encrypted.count))
        packet.appendUInt32(0)
        packet.appendUInt32(deviceID)
        packet.appendUInt32(stamp)
        packet.append(token)
        packet.append(encrypted)
        let checksum = Data(Insecure.MD5.hash(data: packet.prefix(16) + token + encrypted))
        packet.replaceSubrange(16..<32, with: checksum)

        let reply = try roundTrip(packet) { reply in
            // Ignore stale replies to earlier requests.
            guard reply.count > 32, let json = try? self.decode(reply) else { return false }
            return (json["id"] as? Int) == id
        }
        let json = try decode(reply)
        if let err = json["error"] as? [String: Any] {
            throw MiIOError.device(code: err["code"] as? Int ?? -1, message: err["message"] as? String ?? "unknown")
        }
        guard let result = json["result"] else { throw MiIOError.badResponse }
        return result
    }

    private func decode(_ reply: Data) throws -> [String: Any] {
        let plain = try aes(reply.subdata(in: 32..<reply.count), operation: CCOperation(kCCDecrypt))
        let trimmed = plain.prefix { $0 != 0 }
        guard let obj = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else {
            throw MiIOError.badResponse
        }
        return obj
    }

    private func aes(_ input: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var outLength = 0
        let outCapacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, kCCKeySizeAES128, v.baseAddress,
                                inp.baseAddress, input.count, out.baseAddress, outCapacity, &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MiIOError.badResponse }
        return output.prefix(outLength)
    }

    /// Sends `packet` and waits (up to ~2s) for a reply accepted by `accept`.
    private func roundTrip(_ packet: Data, accept: (Data) -> Bool) throws -> Data {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw MiIOError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw MiIOError.invalidHost }

        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { throw MiIOError.socket(String(cString: strerror(errno))) }

        let deadline = Date().addingTimeInterval(2)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw MiIOError.timeout }
                throw MiIOError.socket(String(cString: strerror(errno)))
            }
            let reply = Data(buffer[0..<n])
            if accept(reply) { return reply }
        }
        throw MiIOError.timeout
    }
}

// MARK: - Helpers

extension Data {
    init?(hex: String) {
        let chars = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
        }
        self.init(bytes)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return self[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func appendUInt16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func appendUInt32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}
