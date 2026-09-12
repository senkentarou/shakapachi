// IconCacheTests.swift
// Verifies IconCache.bundledIconURL(forBundleAt:), the static helper that
// locates the .icns file inside a fake app bundle. Covers: CFBundleIconFile
// with and without an extension, a CFBundleIconFile that points at a missing
// file, a missing CFBundleIconFile key (falls back to AppIcon.icns), and a
// bundle with no icns at all (asset-catalog-only apps).
//
// Each test builds a throwaway ".app" directory tree under a unique
// subdirectory of the system temp directory and removes it in teardown.

import XCTest

@testable import ShakaPachi

final class IconCacheTests: XCTestCase {

    // MARK: - Helpers

    private var bundleRoot: URL!

    override func setUp() {
        super.setUp()
        bundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconCacheTests-\(UUID().uuidString)")
            .appendingPathComponent("Fake.app")
        try? FileManager.default.createDirectory(
            at: bundleRoot.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(
            at: bundleRoot.deletingLastPathComponent())
        bundleRoot = nil
        super.tearDown()
    }

    /// Write an Info.plist with the given CFBundleIconFile value (or none) into the fake bundle.
    private func writeInfoPlist(iconFile: String?) throws {
        var dict: [String: Any] = ["CFBundleIdentifier": "com.example.fake"]
        if let iconFile {
            dict["CFBundleIconFile"] = iconFile
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: bundleRoot.appendingPathComponent("Contents/Info.plist"))
    }

    /// Create an empty file at Contents/Resources/<name> inside the fake bundle.
    private func writeResource(named name: String) throws {
        let url = bundleRoot.appendingPathComponent("Contents/Resources/\(name)")
        try Data().write(to: url)
    }

    // MARK: - CFBundleIconFile without an extension

    func testCFBundleIconFile_withoutExtension_resolvesToIcnsFile() throws {
        try writeInfoPlist(iconFile: "AppIcon")
        try writeResource(named: "AppIcon.icns")

        let resolved = IconCache.bundledIconURL(forBundleAt: bundleRoot)

        XCTAssertEqual(
            resolved,
            bundleRoot.appendingPathComponent("Contents/Resources/AppIcon.icns"),
            "A CFBundleIconFile value without an extension must have .icns appended")
    }

    // MARK: - CFBundleIconFile with an extension

    func testCFBundleIconFile_withExtension_resolvesToSameIcnsFile() throws {
        try writeInfoPlist(iconFile: "AppIcon.icns")
        try writeResource(named: "AppIcon.icns")

        let resolved = IconCache.bundledIconURL(forBundleAt: bundleRoot)

        XCTAssertEqual(
            resolved,
            bundleRoot.appendingPathComponent("Contents/Resources/AppIcon.icns"),
            "A CFBundleIconFile value that already has .icns must not be double-suffixed")
    }

    // MARK: - CFBundleIconFile points at a file that does not exist

    func testCFBundleIconFile_missingFile_returnsNil() throws {
        try writeInfoPlist(iconFile: "AppIcon")
        // Deliberately do not write Contents/Resources/AppIcon.icns.

        let resolved = IconCache.bundledIconURL(forBundleAt: bundleRoot)

        XCTAssertNil(
            resolved,
            "A CFBundleIconFile that names a nonexistent file must resolve to nil")
    }

    // MARK: - No CFBundleIconFile key, but the conventional AppIcon.icns exists

    func testNoCFBundleIconFile_fallsBackToConventionalAppIcon() throws {
        try writeInfoPlist(iconFile: nil)
        try writeResource(named: "AppIcon.icns")

        let resolved = IconCache.bundledIconURL(forBundleAt: bundleRoot)

        XCTAssertEqual(
            resolved,
            bundleRoot.appendingPathComponent("Contents/Resources/AppIcon.icns"),
            "Without CFBundleIconFile, Contents/Resources/AppIcon.icns should be tried as a last resort")
    }

    // MARK: - No Info.plist and no icns (asset-catalog-only app)

    func testNoInfoPlistAndNoIcns_returnsNil() {
        // Neither Info.plist nor any .icns resource was written in setUp.
        let resolved = IconCache.bundledIconURL(forBundleAt: bundleRoot)

        XCTAssertNil(
            resolved,
            "A bundle with no Info.plist and no icns file must resolve to nil")
    }
}
