// XHandleParserTests.swift
import XCTest
@testable import XRadarCore

final class XHandleParserTests: XCTestCase {
    func testPlainHandle() throws {
        XCTAssertEqual(try XHandleParser.parse("elonmusk"), "elonmusk")
        XCTAssertEqual(try XHandleParser.parse("jack"), "jack")
        XCTAssertEqual(try XHandleParser.parse("sama"), "sama")
    }

    func testHandleWithAt() throws {
        XCTAssertEqual(try XHandleParser.parse("@elonmusk"), "elonmusk")
        XCTAssertEqual(try XHandleParser.parse("@jack"), "jack")
    }

    func testXURL() throws {
        XCTAssertEqual(try XHandleParser.parse("https://x.com/elonmusk"), "elonmusk")
        XCTAssertEqual(try XHandleParser.parse("https://www.x.com/elonmusk"), "elonmusk")
        XCTAssertEqual(try XHandleParser.parse("x.com/elonmusk"), "elonmusk")
    }

    func testTwitterURL() throws {
        XCTAssertEqual(try XHandleParser.parse("https://twitter.com/elonmusk"), "elonmusk")
        XCTAssertEqual(try XHandleParser.parse("https://www.twitter.com/elonmusk"), "elonmusk")
        XCTAssertEqual(try XHandleParser.parse("twitter.com/elonmusk"), "elonmusk")
    }

    func testURLWithQuery() throws {
        XCTAssertEqual(try XHandleParser.parse("https://x.com/elonmusk?ref=home"), "elonmusk")
    }

    func testURLWithTrailingSlash() throws {
        XCTAssertEqual(try XHandleParser.parse("https://x.com/elonmusk/"), "elonmusk")
    }

    func testInvalidHost() {
        XCTAssertThrowsError(try XHandleParser.parse("https://example.com/elonmusk"))
    }

    func testReservedPaths() {
        XCTAssertThrowsError(try XHandleParser.parse("home"))
        XCTAssertThrowsError(try XHandleParser.parse("explore"))
        XCTAssertThrowsError(try XHandleParser.parse("settings"))
    }

    func testInvalidCharacters() {
        XCTAssertThrowsError(try XHandleParser.parse("elon-musk"))
        XCTAssertThrowsError(try XHandleParser.parse("elon.musk"))
        XCTAssertThrowsError(try XHandleParser.parse("elon@musk"))
    }

    func testLengthValidation() {
        XCTAssertThrowsError(try XHandleParser.parse(""))
        XCTAssertNoThrow(try XHandleParser.parse("a"))
        XCTAssertNoThrow(try XHandleParser.parse("ab"))
        XCTAssertNoThrow(try XHandleParser.parse(String(repeating: "a", count: 15)))
        XCTAssertThrowsError(try XHandleParser.parse(String(repeating: "a", count: 16)))
    }
}
