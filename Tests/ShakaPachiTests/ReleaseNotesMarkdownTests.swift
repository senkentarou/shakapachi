// ReleaseNotesMarkdownTests.swift
// Verifies: ReleaseNotesMarkdown.parse block classification — headings, lists,
// blockquotes, fenced code, tables, horizontal rules — and a regression fixture
// built from the actual v1.4.3 release body (which previously rendered raw
// "|" table rows and a raw ">" blockquote line, see UpdateWindow.swift).

import XCTest

@testable import ShakaPachi

final class ReleaseNotesMarkdownTests: XCTestCase {

    // MARK: - Headings

    func testHeading_capturesLevelOneThroughThree() {
        let blocks = ReleaseNotesMarkdown.parse("# One\n## Two\n### Three")
        XCTAssertEqual(
            blocks,
            [
                .heading(level: 1, text: "One"),
                .heading(level: 2, text: "Two"),
                .heading(level: 3, text: "Three"),
            ])
    }

    func testHeading_requiresSpaceAfterHashes() {
        let blocks = ReleaseNotesMarkdown.parse("#hashtag")
        XCTAssertEqual(blocks, [.paragraph("#hashtag")])
    }

    // MARK: - Lists

    func testListItem_bulletMarkers() {
        let blocks = ReleaseNotesMarkdown.parse("- a\n* b\n+ c\n• d")
        XCTAssertEqual(
            blocks,
            [
                .listItem(indent: 0, marker: .bullet, text: "a"),
                .listItem(indent: 0, marker: .bullet, text: "b"),
                .listItem(indent: 0, marker: .bullet, text: "c"),
                .listItem(indent: 0, marker: .bullet, text: "d"),
            ])
    }

    func testListItem_nestedIndentIsHalfLeadingSpacesCappedAtThree() {
        let blocks = ReleaseNotesMarkdown.parse("- top\n  - one\n    - two\n      - three\n        - stillThree")
        XCTAssertEqual(
            blocks,
            [
                .listItem(indent: 0, marker: .bullet, text: "top"),
                .listItem(indent: 1, marker: .bullet, text: "one"),
                .listItem(indent: 2, marker: .bullet, text: "two"),
                .listItem(indent: 3, marker: .bullet, text: "three"),
                .listItem(indent: 3, marker: .bullet, text: "stillThree"),
            ])
    }

    func testListItem_orderedMarkerCapturesNumber() {
        let blocks = ReleaseNotesMarkdown.parse("1. first\n2. second\n10. tenth")
        XCTAssertEqual(
            blocks,
            [
                .listItem(indent: 0, marker: .ordered(1), text: "first"),
                .listItem(indent: 0, marker: .ordered(2), text: "second"),
                .listItem(indent: 0, marker: .ordered(10), text: "tenth"),
            ])
    }

    // MARK: - Blockquote

    func testQuote_groupsConsecutiveLinesIntoOneBlock() {
        let blocks = ReleaseNotesMarkdown.parse("> line one\n> line two\n\nafter")
        XCTAssertEqual(
            blocks,
            [
                .quote(["line one", "line two"]),
                .blank,
                .paragraph("after"),
            ])
    }

    func testQuote_keepsEmptyQuoteLineAsEmptyString() {
        let blocks = ReleaseNotesMarkdown.parse("> first\n>\n> third")
        XCTAssertEqual(blocks, [.quote(["first", "", "third"])])
    }

    // MARK: - Fenced code

    func testCode_capturesFencedBlockVerbatimWithoutInlineParsing() {
        let blocks = ReleaseNotesMarkdown.parse("```\n# not a heading\n**not bold**\n```")
        XCTAssertEqual(blocks, [.code("# not a heading\n**not bold**")])
    }

    func testCode_unterminatedFenceRunsToEndOfInput() {
        let blocks = ReleaseNotesMarkdown.parse("```\nline one\nline two")
        XCTAssertEqual(blocks, [.code("line one\nline two")])
    }

    // MARK: - Table

    func testTable_parsesHeaderAlignmentsAndRows() {
        let markdown = """
            | A | B |
            |---|---|
            | 1 | 2 |
            | 3 | 4 |
            """
        let blocks = ReleaseNotesMarkdown.parse(markdown)
        XCTAssertEqual(
            blocks,
            [
                .table(
                    ReleaseNoteTable(
                        header: ["A", "B"],
                        alignments: [.leading, .leading],
                        rows: [["1", "2"], ["3", "4"]]))
            ])
    }

    func testTable_parsesCenterAndTrailingAlignments() {
        let markdown = """
            | A | B | C |
            |:---|:---:|---:|
            | a | b | c |
            """
        let blocks = ReleaseNotesMarkdown.parse(markdown)
        guard case .table(let table) = blocks.first else {
            return XCTFail("Expected a single table block")
        }
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
    }

    func testTable_padsShortRowsAndTruncatesLongRows() {
        let markdown = """
            | A | B | C |
            |---|---|---|
            | short |
            | too | many | cells | here |
            """
        let blocks = ReleaseNotesMarkdown.parse(markdown)
        guard case .table(let table) = blocks.first else {
            return XCTFail("Expected a single table block")
        }
        XCTAssertEqual(table.rows, [["short", "", ""], ["too", "many", "cells"]])
    }

    func testTable_delimiterRowIsNotMistakenForHorizontalRule() {
        let markdown = """
            | A |
            |---|
            | 1 |
            """
        let blocks = ReleaseNotesMarkdown.parse(markdown)
        XCTAssertEqual(blocks.count, 1)
        guard case .table = blocks.first else {
            return XCTFail("Expected the delimiter row to be consumed as part of a table, not a rule")
        }
    }

    func testTable_pipeBearingLineFollowedByRuleIsNotATable() {
        let markdown = """
            a | b in prose
            ---
            after
            """
        let blocks = ReleaseNotesMarkdown.parse(markdown)
        XCTAssertEqual(
            blocks,
            [
                .paragraph("a | b in prose"),
                .rule,
                .paragraph("after"),
            ])
    }

    // MARK: - Horizontal rule

    func testRule_dashesAndAsterisksOnTheirOwnLine() {
        let blocks = ReleaseNotesMarkdown.parse("---\n***\n___")
        XCTAssertEqual(blocks, [.rule, .rule, .rule])
    }

    // MARK: - Regression: real v1.4.3 release body

    func testRealReleaseBody_v143_producesOneTableAndOneQuoteWithNoRawMarkdownLeaking() {
        let body = """
            ## 変更（v1.4.2 以降）

            - **パティナの段階を 6 段に組み替え、最上位を 10 万回に緩和** (#43) — 刻みを `0 / 5,000 / 10,000 / 20,000 / 50,000 / 100,000` に組み替えています。

            | 累計切替回数 | 色 | 名前 |
            |---|---|---|
            | 0 | `#8C8A82` | ピューター灰 |
            | 5,000 | `#9B8F6B` | 古銅（新設） |
            | 10,000 | `#AA9455` | ブロンズ |
            | 20,000 | `#C8A63C` | 真鍮 |
            | 50,000 | `#E0B62A` | リッチゴールド |
            | 100,000 | `#EEC814` | ヴィヴィッドゴールド |

            > **既存ユーザーへの注意**: 段の位置そのものが動くため、累計 2 万回未満のうちは色が 1 段戻って見えることがあります。
            > 切替回数の記録自体は変わりません。

            ## インストール

            `ShakaPachi-1.4.3.zip` をダウンロードして展開し、`ShakaPachi.app` を `/Applications` に移動してください。
            """

        let blocks = ReleaseNotesMarkdown.parse(body)

        let tables = blocks.compactMap { block -> ReleaseNoteTable? in
            if case .table(let table) = block { return table }
            return nil
        }
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables.first?.rows.count, 6)

        let quotes = blocks.filter { if case .quote = $0 { return true } else { return false } }
        XCTAssertEqual(quotes.count, 1)

        for block in blocks {
            if case .paragraph(let text) = block {
                XCTAssertFalse(text.hasPrefix("|"), "Paragraph should not carry a raw table row: \(text)")
                XCTAssertFalse(text.hasPrefix(">"), "Paragraph should not carry a raw blockquote line: \(text)")
            }
        }
    }

    // MARK: - localizedSection

    func testLocalizedSection_noMarkersReturnsBodyUnchanged() {
        let body = "## 変更\n\n- 何か直しました"
        XCTAssertEqual(ReleaseNotesMarkdown.localizedSection(from: body, language: "ja"), body)
        XCTAssertEqual(ReleaseNotesMarkdown.localizedSection(from: body, language: "en"), body)
    }

    func testLocalizedSection_selectsMatchingLanguage() {
        let body = """
            <!-- lang:en -->
            ## Changes

            - Fixed something

            <!-- lang:ja -->
            ## 変更

            - 何か直しました
            """

        XCTAssertEqual(
            ReleaseNotesMarkdown.localizedSection(from: body, language: "en"),
            "## Changes\n\n- Fixed something")
        XCTAssertEqual(
            ReleaseNotesMarkdown.localizedSection(from: body, language: "ja"),
            "## 変更\n\n- 何か直しました")
    }

    func testLocalizedSection_outputNeverContainsMarkerLines() {
        let body = "<!-- lang:en -->\nEnglish\n<!-- lang:ja -->\n日本語"
        let en = ReleaseNotesMarkdown.localizedSection(from: body, language: "en")
        let ja = ReleaseNotesMarkdown.localizedSection(from: body, language: "ja")
        XCTAssertFalse(en.contains("<!-- lang:"))
        XCTAssertFalse(ja.contains("<!-- lang:"))
    }

    func testLocalizedSection_unmatchedLanguageFallsBackToFirstSection() {
        let body = "<!-- lang:en -->\nEnglish\n<!-- lang:ja -->\n日本語"
        XCTAssertEqual(ReleaseNotesMarkdown.localizedSection(from: body, language: "fr"), "English")
    }

    func testLocalizedSection_regionSubtagIsIgnored() {
        let body = "<!-- lang:en -->\nEnglish\n<!-- lang:ja -->\n日本語"
        XCTAssertEqual(ReleaseNotesMarkdown.localizedSection(from: body, language: "ja-JP"), "日本語")
    }

    func testLocalizedSection_preambleBeforeFirstMarkerIsKeptAheadOfTheSelectedSection() {
        let body = """
            # ShakaPachi v1.5.0

            <!-- lang:en -->
            ## Changes

            <!-- lang:ja -->
            ## 変更
            """

        XCTAssertEqual(
            ReleaseNotesMarkdown.localizedSection(from: body, language: "ja"),
            "# ShakaPachi v1.5.0\n\n## 変更")
    }

    func testLocalizedSection_extractedTextParsesIntoExpectedBlocks() {
        let body = "<!-- lang:en -->\n## Changes\n\n- one\n<!-- lang:ja -->\n## 変更\n\n- 一つ"
        let extracted = ReleaseNotesMarkdown.localizedSection(from: body, language: "en")
        let blocks = ReleaseNotesMarkdown.parse(extracted)
        XCTAssertEqual(
            blocks,
            [
                .heading(level: 2, text: "Changes"),
                .blank,
                .listItem(indent: 0, marker: .bullet, text: "one"),
            ])
    }
}
