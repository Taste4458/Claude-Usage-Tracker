import XCTest
@testable import Claude_Usage

@MainActor
final class ClaudeAPIUsageTests: XCTestCase {
    func testOAuthRefreshReusesOverageWithoutMixingAccounts() async throws {
        URLProtocol.registerClass(OverageFixtureProtocol.self)
        defer { URLProtocol.unregisterClass(OverageFixtureProtocol.self) }
        OverageFixtureProtocol.lock.withLock { OverageFixtureProtocol.requests = 0 }
        let service = ClaudeAPIService()

        let first = try await service.fetchUsageData(oauthAccessToken: "fixture-a")
        let cached = try await service.fetchUsageData(oauthAccessToken: "fixture-a")
        let other = try await service.fetchUsageData(oauthAccessToken: "fixture-b")

        XCTAssertEqual(first.costUsed, 1234)
        XCTAssertEqual(cached.costUsed, 1234)
        XCTAssertEqual(other.costUsed, 5678)
    }

    func testIncompleteLegacyResponseDoesNotEraseCurrentOverage() async throws {
        URLProtocol.registerClass(OverageFixtureProtocol.self)
        defer { URLProtocol.unregisterClass(OverageFixtureProtocol.self) }

        let usage = try await ClaudeAPIService().fetchUsageData(sessionKey: "fixture", organizationId: "overage-fixture")

        XCTAssertEqual(usage.costUsed, 1234)
        XCTAssertEqual(usage.costLimit, 50000)
        XCTAssertEqual(usage.costCurrency, "EUR")
    }

    func testOAuthOverageSurvivesSavingAndLoading() throws {
        let data = Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":50000,"currency":"EUR","decimal_places":2}}"#.utf8)
        let usage = try ClaudeAPIService().parseUsageResponse(data)
        let restored = try JSONDecoder().decode(ClaudeUsage.self, from: JSONEncoder().encode(usage))

        XCTAssertEqual(restored.costUsed, 1234)
        XCTAssertEqual(restored.costLimit, 50000)
        XCTAssertEqual(restored.costCurrency, "EUR")
    }

    func testLegacyOverageDefaultsToUSDCents() throws {
        let data = Data(#"{"extra_usage":{"is_enabled":true,"used_credits":541,"monthly_limit":2000}}"#.utf8)
        let usage = try ClaudeAPIService().parseUsageResponse(data)

        XCTAssertEqual(usage.costUsed, 541)
        XCTAssertEqual(usage.costLimit, 2000)
        XCTAssertEqual(usage.costCurrency, "USD")
    }

    func testOverageUnitsMatchExistingCentsBasedDisplay() throws {
        let data = Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":50000,"currency":"JPY","decimal_places":0}}"#.utf8)
        let usage = try ClaudeAPIService().parseUsageResponse(data)

        XCTAssertEqual(usage.costUsed, 123400)
        XCTAssertEqual(usage.costLimit, 5000000)
        XCTAssertEqual(usage.costCurrency, "JPY")
    }

    func testDisabledAndMissingOverageStayHidden() throws {
        for json in [#"{}"#, #"{"extra_usage":null}"#, #"{"extra_usage":{"is_enabled":false,"used_credits":1234,"monthly_limit":50000}}"#] {
            let usage = try ClaudeAPIService().parseUsageResponse(Data(json.utf8))
            XCTAssertNil(usage.costUsed)
            XCTAssertNil(usage.costLimit)
            XCTAssertNil(usage.costCurrency)
        }
    }
}

private final class OverageFixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool {
        (request.url?.host == "claude.ai" && request.url?.path.contains("/organizations/overage-fixture/") == true)
            || (request.url?.host == "api.anthropic.com"
                && request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer fixture-") == true)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: String
        if request.url!.host == "api.anthropic.com" {
            let spent = Self.lock.withLock {
                Self.requests += 1
                return Self.requests == 1 ? 1234 : 5678
            }
            body = "{\"extra_usage\":{\"is_enabled\":true,\"used_credits\":\(spent),\"monthly_limit\":50000,\"currency\":\"EUR\"}}"
        } else {
            body = request.url!.lastPathComponent == "usage"
                ? #"{"extra_usage":{"is_enabled":true,"used_credits":1234,"monthly_limit":50000,"currency":"EUR"}}"#
                : #"{"is_enabled":true,"currency":"EUR"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
