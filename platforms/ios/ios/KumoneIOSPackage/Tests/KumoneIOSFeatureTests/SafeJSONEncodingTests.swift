import XCTest
@testable import KumoneCore

/// Regression tests for the SIGABRT captured in
/// iMusic-Diagnostics-20261118-162720.txt. `NSJSONSerialization` raises an
/// uncatchable NSException for a scalar top-level value, so these assertions
/// also act as an "does not abort the test process" check.
final class SafeJSONEncodingTests: XCTestCase {
    /// `__set_timeout__` passes an Int timer id; the JS bridge expects
    /// `JSON.parse("123")` to produce a number.
    func testScalarTopLevelIntegerIsEmittedAsJSONFragment() {
        XCTAssertEqual(SafeJSON.encodedString(123), "123")
        XCTAssertEqual(SafeJSON.encodedString(0), "0")
    }

    func testOtherScalarFragments() {
        XCTAssertEqual(SafeJSON.encodedString(true), "true")
        XCTAssertEqual(SafeJSON.encodedString("hello"), "\"hello\"")
        XCTAssertEqual(SafeJSON.encodedString(NSNull()), "null")
    }

    func testDictionaryStillEncodesAsObject() throws {
        let data = try XCTUnwrap(SafeJSON.encodedData(["a": 1, "b": [1, 2]]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["a"] as? Int, 1)
        XCTAssertEqual((object["b"] as? [Int])?.count, 2)
    }

    func testUnsupportedNestedValuesAreNormalisedInsteadOfThrowing() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a"))
        let nested: [String: Any] = [
            "url": url,
            "date": Date(timeIntervalSince1970: 1),
            "optional": Optional<Int>.some(7) as Any,
            "nothing": Optional<Int>.none as Any,
        ]
        let data = try XCTUnwrap(SafeJSON.encodedData(nested))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["url"] as? String, "https://example.com/a")
        XCTAssertEqual(object["optional"] as? Int, 7)
        XCTAssertTrue(object["nothing"] is NSNull)
    }

    func testFragmentsCanBeDisabledForHTTPBodies() {
        XCTAssertNil(SafeJSON.encodedData(123, allowFragments: false))
        XCTAssertNotNil(SafeJSON.encodedData(["a": 1], allowFragments: false))
    }

    func testNilProducesNoArgument() {
        XCTAssertNil(SafeJSON.encodedString(nil))
    }
}
