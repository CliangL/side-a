import XCTest
@testable import SideA

final class KuwoResourceLoaderTests: XCTestCase {
    func testPublicHeadersStayWithinOfficialHTTPSCDN() {
        for value in ["https://kw-sy-sycdn.kuwo.cn/a.mp3", "https://KW-A.KUWO.CN:443/a.flac"] {
            let url = URL(string: value)!
            XCTAssertTrue(KuwoResourceLoader.supports(url))
            let request = KuwoResourceLoader.request(url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.kuwo.cn/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
        for value in ["https://kw-a.kuwo.cn.evil.test/a.mp3", "https://x.kw-a.kuwo.cn/a", "https://kw-a.kuwo.cn:8443/a", "https://user:pass@kw-a.kuwo.cn/a", "http://kw-a.kuwo.cn/a", "https://cdn.test/a"] {
            let url = URL(string: value)!
            XCTAssertFalse(KuwoResourceLoader.supports(url))
            XCTAssertNil(KuwoResourceLoader.request(url).value(forHTTPHeaderField: "Referer"))
        }
    }
    func testValidRangeRequiresExactOffsetAndFullLength() throws {
        let url = URL(string: "https://kw-a.kuwo.cn/a.mp3")!
        let valid = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
            headerFields: ["Content-Length":"64", "Content-Range":"bytes 500-563/4644804"])!
        XCTAssertEqual(KuwoResourceLoader.responseRange(valid, requestedStart: 500), .init(start: 500, end: 563, total: 4644804))
        XCTAssertNil(KuwoResourceLoader.responseRange(valid, requestedStart: 0))
        for header in ["bytes 500-563/*", "bytes 500-499/1000", "bytes 500-1000/1000", "bytes 500-563/0", "500-563/1000", "bytes 500-563/999999999999999999999999"] {
            let bad = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range":header])!
            XCTAssertNil(KuwoResourceLoader.responseRange(bad, requestedStart: 500))
        }
        let full = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length":"4644804"])!
        XCTAssertEqual(KuwoResourceLoader.responseRange(full, requestedStart: 500), .init(start: 0, end: 4644803, total: 4644804))
    }
}
