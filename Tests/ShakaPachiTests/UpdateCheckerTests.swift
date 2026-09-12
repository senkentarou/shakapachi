// UpdateCheckerTests.swift
// Verifies: SemanticVersion parsing and ordering, and UpdateChecker.parseLatestRelease
// with fixture JSON — both the success path and the no-matching-asset error path.

import XCTest

@testable import ShakaPachi

final class UpdateCheckerTests: XCTestCase {

    // MARK: - SemanticVersion: parsing

    func testSemanticVersion_parsesPlainString() {
        let v = SemanticVersion("1.2.3")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 3)
    }

    func testSemanticVersion_parsesVPrefixedString() {
        let v = SemanticVersion("v1.2.3")
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.major, 1)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 3)
    }

    func testSemanticVersion_returnsNilForInvalidString() {
        XCTAssertNil(SemanticVersion("not-a-version"))
        XCTAssertNil(SemanticVersion("1.2"))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("a.b.c"))
    }

    func testSemanticVersion_description() {
        XCTAssertEqual(SemanticVersion("1.2.3")?.description, "1.2.3")
        XCTAssertEqual(SemanticVersion("v0.10.0")?.description, "0.10.0")
    }

    // MARK: - SemanticVersion: ordering

    func testSemanticVersion_patchOrdering() {
        let v100 = SemanticVersion("1.0.0")!
        let v101 = SemanticVersion("1.0.1")!
        XCTAssertLessThan(v100, v101)
        XCTAssertGreaterThan(v101, v100)
    }

    func testSemanticVersion_minorOrdering() {
        let v100 = SemanticVersion("1.0.0")!
        let v110 = SemanticVersion("1.1.0")!
        XCTAssertLessThan(v100, v110)
        XCTAssertGreaterThan(v110, v100)
    }

    func testSemanticVersion_majorOrdering() {
        let v110 = SemanticVersion("1.1.0")!
        let v200 = SemanticVersion("2.0.0")!
        XCTAssertLessThan(v110, v200)
        XCTAssertGreaterThan(v200, v110)
    }

    func testSemanticVersion_equalVersions() {
        let v1 = SemanticVersion("1.0.0")!
        let v2 = SemanticVersion("1.0.0")!
        XCTAssertEqual(v1, v2)
        XCTAssertFalse(v1 < v2)
        XCTAssertFalse(v2 < v1)
    }

    func testSemanticVersion_fullOrdering() {
        let versions = [
            SemanticVersion("1.0.0")!,
            SemanticVersion("1.0.1")!,
            SemanticVersion("1.1.0")!,
            SemanticVersion("2.0.0")!,
        ]
        // The array is already sorted — verify that each element < the next.
        for i in 0..<(versions.count - 1) {
            XCTAssertLessThan(versions[i], versions[i + 1])
        }
    }

    // MARK: - UpdateChecker.parseLatestRelease: success path

    /// A realistic minimal GitHub /releases/latest payload containing a
    /// ShakaPachi-1.1.0.zip asset.
    private let fixtureJSON = """
    {
      "tag_name": "v1.1.0",
      "name": "ShakaPachi 1.1.0",
      "body": "## What's new\\n- Auto-update support",
      "html_url": "https://github.com/senkentarou/shakapachi/releases/tag/v1.1.0",
      "published_at": "2026-06-01T12:00:00Z",
      "assets": [
        {
          "name": "ShakaPachi-1.1.0.zip",
          "browser_download_url": "https://github.com/senkentarou/shakapachi/releases/download/v1.1.0/ShakaPachi-1.1.0.zip",
          "size": 12345678
        }
      ]
    }
    """

    func testParseLatestRelease_version() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let info = try UpdateChecker.parseLatestRelease(from: data)
        XCTAssertEqual(info.version, SemanticVersion("1.1.0")!)
    }

    func testParseLatestRelease_tagName() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let info = try UpdateChecker.parseLatestRelease(from: data)
        XCTAssertEqual(info.tagName, "v1.1.0")
    }

    func testParseLatestRelease_downloadURL() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let info = try UpdateChecker.parseLatestRelease(from: data)
        XCTAssertEqual(
            info.downloadURL.absoluteString,
            "https://github.com/senkentarou/shakapachi/releases/download/v1.1.0/ShakaPachi-1.1.0.zip"
        )
    }

    func testParseLatestRelease_assetName() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let info = try UpdateChecker.parseLatestRelease(from: data)
        XCTAssertEqual(info.assetName, "ShakaPachi-1.1.0.zip")
    }

    func testParseLatestRelease_notes() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let info = try UpdateChecker.parseLatestRelease(from: data)
        XCTAssertTrue(info.notes.contains("Auto-update support"))
    }

    func testParseLatestRelease_assetSize() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let info = try UpdateChecker.parseLatestRelease(from: data)
        XCTAssertEqual(info.assetSize, 12_345_678)
    }

    func testParseLatestRelease_publishedAt() throws {
        let data = fixtureJSON.data(using: .utf8)!
        let info = try UpdateChecker.parseLatestRelease(from: data)
        XCTAssertNotNil(info.publishedAt)
    }

    // MARK: - UpdateChecker.parseLatestRelease: no matching asset

    func testParseLatestRelease_throwsWhenNoMatchingAsset() {
        let json = """
        {
          "tag_name": "v1.1.0",
          "name": "ShakaPachi 1.1.0",
          "body": "",
          "html_url": "https://github.com/senkentarou/shakapachi/releases/tag/v1.1.0",
          "published_at": "2026-06-01T12:00:00Z",
          "assets": [
            {
              "name": "SomeOtherFile.dmg",
              "browser_download_url": "https://example.com/SomeOtherFile.dmg",
              "size": 999
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try UpdateChecker.parseLatestRelease(from: data)) { error in
            guard case UpdateError.noMatchingAsset = error else {
                XCTFail("Expected UpdateError.noMatchingAsset, got \(error)")
                return
            }
        }
    }

    func testParseLatestRelease_throwsWhenTagIsUnparseable() {
        let json = """
        {
          "tag_name": "not-a-version",
          "name": "Bad Release",
          "body": "",
          "html_url": "https://github.com/senkentarou/shakapachi/releases/tag/bad",
          "published_at": null,
          "assets": [
            {
              "name": "ShakaPachi-1.1.0.zip",
              "browser_download_url": "https://example.com/ShakaPachi-1.1.0.zip",
              "size": 100
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try UpdateChecker.parseLatestRelease(from: data)) { error in
            guard case UpdateError.parseError = error else {
                XCTFail("Expected UpdateError.parseError, got \(error)")
                return
            }
        }
    }
}
