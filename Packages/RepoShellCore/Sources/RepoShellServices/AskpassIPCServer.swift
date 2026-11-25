import Foundation
import Darwin
import RepoShellShared

public final class AskpassIPCServer: @unchecked Sendable {
    public typealias PromptHandler = @Sendable (AskpassIPCRequest) async -> AskpassIPCResponse

    private let socketURL: URL
    private let storage: SharedStorage
    private let promptHandler: PromptHandler
    private let queue = DispatchQueue(label: "com.leaf.reposhell.askpass.ipc", qos: .userInitiated)

    private var listenFD: Int32 = -1
    private var running = false

    public init(
        storage: SharedStorage = .shared,
        promptHandler: @escaping PromptHandler
    ) {
        self.storage = storage
        self.socketURL = storage.askpassSocketURL
        self.promptHandler = promptHandler
    }

    deinit {
        stop()
    }

    public func start() {
        queue.async { [weak self] in
            self?.runAcceptLoop()
        }
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func runAcceptLoop() {
        let fm = FileManager.default
        try? fm.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: socketURL)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketURL.path.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dest in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dest, src.baseAddress, src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            return
        }

        chmod(socketURL.path, 0o600)

        guard Darwin.listen(fd, 8) == 0 else {
            close(fd)
            return
        }

        listenFD = fd
        running = true

        while running {
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                if !running { break }
                continue
            }
            handleClient(fd: clientFD)
        }
    }

    private func handleClient(fd clientFD: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                close(clientFD)
                return
            }
            defer { close(clientFD) }

            var requestData = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(clientFD, &buf, buf.count)
                if n <= 0 { break }
                requestData.append(contentsOf: buf[0..<n])
                if requestData.contains(0x0A) { break }
            }

            let lineData = requestData.split(separator: 0x0A).first.map { Data($0) } ?? requestData
            guard let request = try? JSONDecoder().decode(AskpassIPCRequest.self, from: lineData) else {
                return
            }

            let semaphore = DispatchSemaphore(value: 0)
            var finalResponse = AskpassIPCResponse(approved: false)

            Task {
                finalResponse = await self.promptHandler(request)
                if finalResponse.approved && finalResponse.saveToKeychain && !request.repoPath.isEmpty {
                    let account = PathUtils.normalize(request.repoPath)
                    switch request.kind {
                    case .passphrase:
                        _ = KeychainStore.saveSecret(finalResponse.secret, service: AppConstants.keychainSshService, account: account)
                    case .password, .credential:
                        _ = KeychainStore.saveSecret(finalResponse.secret, service: AppConstants.keychainGitService, account: account)
                    default:
                        break
                    }
                }
                semaphore.signal()
            }

            semaphore.wait()

            if var respData = try? JSONEncoder().encode(finalResponse) {
                respData.append(0x0A)
                respData.withUnsafeBytes { rawBuf in
                    if let base = rawBuf.baseAddress {
                        var sent = 0
                        while sent < respData.count {
                            let n = Darwin.write(clientFD, base.advanced(by: sent), respData.count - sent)
                            if n <= 0 { break }
                            sent += n
                        }
                    }
                }
            }
        }
    }
}
