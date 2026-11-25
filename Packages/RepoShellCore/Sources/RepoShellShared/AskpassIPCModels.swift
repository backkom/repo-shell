import Foundation
import Darwin

public enum AskpassRequestKind: String, Codable, Sendable {
    case username
    case password
    case passphrase
    case hostTrust
    case credential
}

public struct AskpassIPCRequest: Codable, Sendable {
    public var requestId: UUID
    public var kind: AskpassRequestKind
    public var prompt: String
    public var repoPath: String
    public var remoteHost: String
    public var protocolName: String
    public var defaultUsername: String

    public init(
        requestId: UUID = UUID(),
        kind: AskpassRequestKind,
        prompt: String,
        repoPath: String,
        remoteHost: String = "",
        protocolName: String = "",
        defaultUsername: String = ""
    ) {
        self.requestId = requestId
        self.kind = kind
        self.prompt = prompt
        self.repoPath = repoPath
        self.remoteHost = remoteHost
        self.protocolName = protocolName
        self.defaultUsername = defaultUsername
    }
}

public struct AskpassIPCResponse: Codable, Sendable {
    public var approved: Bool
    public var username: String
    public var secret: String
    public var saveToKeychain: Bool

    public init(
        approved: Bool,
        username: String = "",
        secret: String = "",
        saveToKeychain: Bool = false
    ) {
        self.approved = approved
        self.username = username
        self.secret = secret
        self.saveToKeychain = saveToKeychain
    }
}

public enum AskpassSocketClient {
    public static func send(request: AskpassIPCRequest, socketURL: URL, timeoutSeconds: TimeInterval = 120) -> AskpassIPCResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketURL.path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dest, src.baseAddress, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addrLen)
            }
        }
        guard connectResult == 0 else { return nil }

        guard var payload = try? JSONEncoder().encode(request) else { return nil }
        payload.append(0x0A) // newline delimiter

        let sent = payload.withUnsafeBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return -1 }
            var total = 0
            while total < payload.count {
                let n = Darwin.write(fd, base.advanced(by: total), payload.count - total)
                if n <= 0 { return -1 }
                total += n
            }
            return total
        }
        guard sent == payload.count else { return nil }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            responseData.append(contentsOf: buffer[0..<n])
            if responseData.contains(0x0A) {
                break
            }
        }
        let lineData = responseData.split(separator: 0x0A).first.map { Data($0) } ?? responseData
        return try? JSONDecoder().decode(AskpassIPCResponse.self, from: lineData)
    }
}
