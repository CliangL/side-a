import SwiftUI

struct SearchCatalog: Codable, Hashable, Sendable {
    static let gdEndpoint = URL(string: "https://music-api.gdstudio.xyz/api.php")!
    static let netease = SearchCatalog(name: "网易云音乐", source: "netease", endpoint: gdEndpoint)
    static let builtIns = [
        netease,
        SearchCatalog(name: "JOOX", source: "joox", endpoint: gdEndpoint),
        SearchCatalog(name: "哔哩哔哩", source: "bilibili", endpoint: gdEndpoint)
    ]

    let name: String
    let source: String
    let endpoint: URL
    var managed: Bool? = nil
    // Filter applies only to search. Playback and saved recordings retain their central ID.
    var provider: String? = nil

    func contains(_ track: Track) -> Bool {
        source == track.source && endpoint == track.apiEndpoint &&
        (provider.map { track.managedCatalog == true && track.trackID.hasPrefix($0 + ".") } ?? true)
    }

    static func custom(name: String, source: String, address: String) throws -> SearchCatalog {
        let code = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil else {
            throw MusicFailure.message("请填写接口文档中的 source 代码，如 netease。只支持字母、数字、下划线和短横线。")
        }
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw MusicFailure.message("请填写完整 HTTPS API 地址，不要附账号、密码、查询参数或片段。")
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        guard let endpoint = parts.url else { throw MusicFailure.message("无法识别此 API 地址。") }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchCatalog(name: label.isEmpty ? code : label, source: code, endpoint: endpoint)
    }
}

@MainActor
final class SearchCatalogSettings: ObservableObject {
    private struct Saved: Codable {
        var selected = "all"
    }
    private let defaults: UserDefaults
    private let key = "sidea.search.catalog.v1"
    @Published private var saved: Saved
    @Published private(set) var centralBase: URL?
    private var automaticTask: Task<Void, Never>?
    var onPersist: (() -> Void)?
    var central: SearchCatalog {
        SearchCatalog(name: "全部", source: "central",
                      endpoint: (centralBase ?? CentralServer.personalBase).appending(path: "v1/music"), managed: true)
    }

    struct Scope: Identifiable {
        let id: String
        let title: String
    }
    static let scopes = [Scope(id: "all", title: "全部"), Scope(id: "qq", title: "QQ 音乐"),
                         Scope(id: "wy", title: "网易云"), Scope(id: "kw", title: "酷我音乐"), Scope(id: "jx", title: "JOOX")]
    func catalog(for provider: String) -> SearchCatalog {
        guard provider != "all", let scope = Self.scopes.first(where: { $0.id == provider }) else { return central }
        return SearchCatalog(name: scope.title, source: central.source, endpoint: central.endpoint, managed: true, provider: provider)
    }
    var qqMusic: SearchCatalog { catalog(for: "qq") }
    var selectedProvider: String { saved.selected }
    var selectedCatalog: SearchCatalog { catalog(for: saved.selected) }

    init(defaults: UserDefaults = LocalStorage.defaults) {
        self.defaults = defaults
        centralBase = (try? CentralServer.read())?.base
        saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        if !Self.scopes.contains(where: { $0.id == saved.selected }) { saved.selected = "all" }
    }

    func ensureConnected() async {
        if centralBase != nil { return }
        if let task = automaticTask { await task.value; return }
        let task = Task { @MainActor in
            do {
                if let existing = try CentralServer.read() {
                    centralBase = existing.base
                    return
                }
                var name = UIDevice.current.name
#if DEBUG
                if let testID = LocalStorage.testID {
                    guard ProcessInfo.processInfo.environment["SIDEA_TEST_AUTO_ENROLL"] == "1" else { return }
                    name = "Side A iOS 验收 " + testID
                }
#endif
                guard let resource = Bundle.main.url(forResource: "SideASetup", withExtension: "txt"),
                      let ticket = try? String(contentsOf: resource, encoding: .ascii).trimmingCharacters(in: .whitespacesAndNewlines),
                      !ticket.isEmpty, ticket.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return }
                let installation = try CentralServer.installation()
                guard installation.automatic else { return }
                let session = CentralServer.session()
                defer { session.invalidateAndCancel() }
                let recovery = try CentralServer.libraryRecovery()
                let server = try await CentralServer.enroll(installation, ticket: ticket, name: name, recovery: recovery, using: session)
                try Task.checkCancellation()
                guard try CentralServer.read() == nil, try CentralServer.installation().automatic else { return }
                try CentralServer.save(server)
                centralBase = server.base
            } catch { /* Retry on the next activation or search. */ }
        }
        automaticTask = task
        await task.value
        automaticTask = nil
    }

    var isQQ: Bool { saved.selected == "qq" }
    var activeCatalogs: [SearchCatalog] { [selectedCatalog] }

    func selectQQ(_ enabled: Bool) { selectProvider(enabled ? "qq" : "all") }
    func selectProvider(_ provider: String) {
        saved.selected = Self.scopes.contains(where: { $0.id == provider }) ? provider : "all"
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
        onPersist?()
    }
}
