import SwiftUI
import Security

struct PairedServer: Codable, Equatable {
    var id = UUID()
    let base: URL
    let token: String
    var endpoint: URL { base.appending(path: "v1/music") }
    var catalog: SearchCatalog { SearchCatalog(name: "统一曲库", source: "central", endpoint: endpoint, managed: true) }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CentralServer {
    static let personalBase = URL(string: "https://music.cliang.top")!
    static func base(_ address: String) throws -> URL {
        try SearchCatalog.custom(name: "", source: "central", address: address).endpoint
    }
    static func session(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private static func key(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "studio.sidea.central." + (LocalStorage.testID ?? "device"),
         kSecAttrAccount as String: account]
    }

    private static func storedData(_ account: String) throws -> Data? {
        var query = key(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MusicFailure.message("无法读取设备配对，请先解锁 iPhone。")
        }
        return data
    }
    static func read() throws -> PairedServer? {
        try storedData("paired-server").map { try JSONDecoder().decode(PairedServer.self, from: $0) }
    }
    private static func write(_ value: Data, account: String) throws {
        let query = key(account)
        let update = [kSecValueData as String: value] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MusicFailure.message("无法安全保存配对，请先解锁 iPhone。") }
    }
    static func save(_ server: PairedServer) throws {
        try write(JSONEncoder().encode(server), account: "paired-server")
    }
    static func remove() throws {
        let status = SecItemDelete(key("paired-server") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MusicFailure.message("无法解除本机配对，请先解锁 iPhone。")
        }
    }

    struct Installation: Codable {
        let id: UUID
        var automatic: Bool
    }
    @MainActor static func installation() throws -> Installation {
        if let data = try storedData("installation") {
            return try JSONDecoder().decode(Installation.self, from: data)
        }
        let installation = Installation(id: UUID(), automatic: true)
        try write(JSONEncoder().encode(installation), account: "installation")
        return installation
    }
    static func libraryRecovery() throws -> String {
        if let saved = try storedData("library-recovery") {
            guard let value = String(data: saved, encoding: .ascii),
                  value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw URLError(.cannotDecodeContentData) }
            return value
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw URLError(.unknown) }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        try write(Data(value.utf8), account: "library-recovery")
        return value
    }

    static func enroll(_ installation: Installation, ticket: String, name: String, recovery: String? = nil, using session: URLSession) async throws -> PairedServer {
        let base = personalBase
        var request = URLRequest(url: base.appending(path: "v1/enroll"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SideA-Setup " + ticket, forHTTPHeaderField: "Authorization")
        var body = ["installation": installation.id.uuidString.lowercased(), "name": name]
        if let recovery { body["recovery"] = recovery; body["platform"] = "ios" }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, [200,201].contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decodedServer(data, base: base)
    }

    private static func decodedServer(_ data: Data, base: URL) throws -> PairedServer {
        struct Reply: Decodable { let token: String }
        guard let token = try? JSONDecoder().decode(Reply.self, from: data).token,
              !token.isEmpty, token.utf8.count <= 4096, token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw MusicFailure.message("后台没有返回可用的设备凭证。")
        }
        return PairedServer(base: base, token: token)
    }
    static func data(for request: URLRequest, endpoint: URL, using session: URLSession) async throws -> Data {
        guard let server = try read(), server.endpoint == endpoint else {
            throw MusicFailure.message("这首歌的曲库尚未连接。")
        }
        guard let url = request.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        parts.query = nil
        guard parts.url == endpoint else { throw URLError(.badURL) }
        var authenticated = request
        authenticated.setValue("Bearer " + server.token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: authenticated)
        guard try read() == server else { throw MusicFailure.message("设备配对已变更，请重新搜索。") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw MusicFailure.message("此设备的曲库授权已失效。已保存的收藏仍可查看。")
        }
        guard (200..<300).contains(status) else {
            struct Failure: Decodable { let error: String }
            if data.count <= 8192, let reason = try? JSONDecoder().decode(Failure.self, from: data).error,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 180,
               !reason.contains(server.token) {
                throw MusicFailure.message(reason)
            }
            throw MusicFailure.message("统一后台返回 HTTP \(status)，请检查后台连接或曲库状态。")
        }
        return data
    }
}
