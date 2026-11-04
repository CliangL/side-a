import Foundation
import AVFoundation
import UniformTypeIdentifiers

// Kuwo's public CDN requires its website Referer. This loader keeps playback native
// and sends byte ranges directly from the phone, with no device/server credentials.
final class KuwoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static func supports(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host.range(of: #"^kw-[a-z0-9-]+\.kuwo\.cn$"#, options: .regularExpression) != nil
    }
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if supports(url) { request.setValue("https://www.kuwo.cn/", forHTTPHeaderField: "Referer") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
    struct ResponseRange: Equatable {
        let start: Int64
        let end: Int64
        let total: Int64
    }
    static func responseRange(_ response: HTTPURLResponse, requestedStart: Int64) -> ResponseRange? {
        if response.statusCode == 200, response.expectedContentLength > 0 {
            return ResponseRange(start: 0, end: response.expectedContentLength - 1, total: response.expectedContentLength)
        }
        guard response.statusCode == 206,
              let raw = response.value(forHTTPHeaderField: "Content-Range"),
              raw.range(of: #"^bytes [0-9]+-[0-9]+/[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        let parts = raw.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 3, let start = Int64(parts[0]), let end = Int64(parts[1]), let total = Int64(parts[2]),
              start == requestedStart, start >= 0, end >= start, end < total else { return nil }
        return ResponseRange(start: start, end: end, total: total)
    }

    let queue = DispatchQueue(label: "sidea.kuwo.resource", qos: .userInitiated)
    private let original: URL
    private var invalidated = false
    private var waiting: [AVAssetResourceLoadingRequest] = []
    private var active: [Int: Pending] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 1_800
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    private final class Pending {
        let request: AVAssetResourceLoadingRequest
        let task: URLSessionDataTask
        let requestedStart: Int64
        var responseOffset: Int64 = 0
        var responseEnd: Int64?
        var requiredEnd: Int64?
        init(_ request: AVAssetResourceLoadingRequest, _ task: URLSessionDataTask) {
            self.request = request; self.task = task
            requestedStart = request.dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
        }
    }

    init(url: URL) { original = url; super.init() }
    func asset() -> AVURLAsset {
        var components = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        components.scheme = "sidea-kuwo"
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }
    func invalidate() {
        queue.async {
            guard !self.invalidated else { return }
            self.invalidated = true
            for request in self.waiting where !request.isFinished && !request.isCancelled { request.finishLoading(with: URLError(.cancelled)) }
            self.waiting.removeAll()
            for item in self.active.values {
                item.task.cancel()
                if !item.request.isFinished && !item.request.isCancelled { item.request.finishLoading(with: URLError(.cancelled)) }
            }
            self.active.removeAll()
            self.session.invalidateAndCancel()
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme == "sidea-kuwo" else { return false }
        guard !invalidated, Self.supports(original), waiting.count < 16 else {
            request.finishLoading(with: URLError(.cancelled)); return true
        }
        waiting.append(request); pump()
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        waiting.removeAll { $0 === loadingRequest }
        if let key = active.first(where: { $0.value.request === loadingRequest })?.key {
            active.removeValue(forKey: key)?.task.cancel()
        }
        pump()
    }
    private func pump() {
        while !invalidated && active.count < 3 && !waiting.isEmpty {
            let request = waiting.removeFirst()
            guard !request.isCancelled && !request.isFinished else { continue }
            var http = Self.request(original)
            if let data = request.dataRequest {
                let start = max(data.requestedOffset, data.currentOffset)
                if data.requestsAllDataToEndOfResource { http.setValue("bytes=\(start)-", forHTTPHeaderField: "Range") }
                else {
                    let end = data.requestedOffset + Int64(data.requestedLength) - 1
                    guard end >= start else { request.finishLoading(); continue }
                    http.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                }
            } else { http.setValue("bytes=0-1", forHTTPHeaderField: "Range") }
            let task = session.dataTask(with: http)
            active[task.taskIdentifier] = Pending(request, task)
            task.resume()
        }
    }
    private func finish(_ id: Int, error: Error? = nil, cancel: Bool = false) {
        guard let item = active.removeValue(forKey: id) else { return }
        if cancel { item.task.cancel() }
        if !item.request.isFinished && !item.request.isCancelled {
            if let error { item.request.finishLoading(with: error) }
            else { item.request.finishLoading() }
        }
        pump()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async {
            guard let pending = self.active[dataTask.taskIdentifier], !pending.request.isCancelled,
                  let http = response as? HTTPURLResponse, [200,206].contains(http.statusCode),
                  let url = http.url, Self.supports(url), let range = Self.responseRange(http, requestedStart: pending.requestedStart) else {
                completionHandler(.cancel)
                self.finish(dataTask.taskIdentifier, error: URLError(.badServerResponse))
                return
            }
            pending.responseOffset = range.start
            pending.responseEnd = range.end
            if let data = pending.request.dataRequest {
                pending.requiredEnd = data.requestsAllDataToEndOfResource ? range.total : min(range.total, data.requestedOffset + Int64(data.requestedLength))
            }
            if let info = pending.request.contentInformationRequest {
                let type = http.mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: self.original.pathExtension) ?? .mp3
                info.contentType = type.identifier
                info.contentLength = range.total
                info.isByteRangeAccessSupported = http.statusCode == 206 || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
            }
            if pending.request.dataRequest == nil {
                completionHandler(.cancel); self.finish(dataTask.taskIdentifier); return
            }
            completionHandler(.allow)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async {
            guard let pending = self.active[dataTask.taskIdentifier], !pending.request.isCancelled,
                  let request = pending.request.dataRequest else { return }
            if let end = pending.responseEnd, Int64(data.count) > end + 1 - pending.responseOffset {
                self.finish(dataTask.taskIdentifier, error: URLError(.badServerResponse), cancel: true)
                return
            }
            let needed = max(request.requestedOffset, request.currentOffset)
            let skip = max(Int64(0), needed - pending.responseOffset)
            pending.responseOffset += Int64(data.count)
            guard skip < data.count else { return }
            var count = data.count - Int(skip)
            if !request.requestsAllDataToEndOfResource {
                count = min(count, max(0, Int(request.requestedOffset + Int64(request.requestedLength) - needed)))
            }
            if count > 0 { request.respond(with: data.subdata(in: Int(skip)..<(Int(skip) + count))) }
            if !request.requestsAllDataToEndOfResource && request.currentOffset >= request.requestedOffset + Int64(request.requestedLength) {
                self.finish(dataTask.taskIdentifier, cancel: true)
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async {
            if error == nil, let pending = self.active[task.taskIdentifier], let request = pending.request.dataRequest,
               let required = pending.requiredEnd, max(request.currentOffset, request.requestedOffset) < required {
                self.finish(task.taskIdentifier, error: URLError(.networkConnectionLost))
            } else { self.finish(task.taskIdentifier, error: error) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.supports(url) else { completionHandler(nil); return }
        var safe = Self.request(url)
        safe.setValue(task.originalRequest?.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
        completionHandler(safe)
    }
}

// URLSession's initial header probe follows the same CDN allowlist as the resource loader.
final class KuwoProbeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, KuwoResourceLoader.supports(original) else { completionHandler(request); return }
        guard let next = request.url, KuwoResourceLoader.supports(next) else { completionHandler(nil); return }
        var safe = KuwoResourceLoader.request(next)
        safe.setValue(task.originalRequest?.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
        completionHandler(safe)
    }
}
