import XCTest
import CoreGraphics
@testable import SpaceOKit

final class NativeTextInputTests: XCTestCase {
    private final class Field {
        var value: String
        var selection: CFRange
        var writes = 0
        var selections = 0
        var ignoreSelect = false
        var ignoreInsert = false
        init(_ value: String, selection: CFRange = .init(location: 0, length: 0)) {
            self.value = value; self.selection = selection
        }
        func driver(canSelect: Bool = true, canInsert: Bool = true) -> NativeTextInput.Driver {
            .init(canSelect: canSelect, canInsert: canInsert, value: { self.value },
                selection: { self.selection }, select: { range in
                    self.selections += 1
                    if !self.ignoreSelect { self.selection = range }
                }, insert: { text in
                    self.writes += 1
                    if !self.ignoreInsert {
                        self.value = try NativeTextInput.expectedValue(self.value, selection: self.selection, text: text)
                        self.selection = .init(location: self.selection.location + text.utf16.count, length: 0)
                    }
                })
        }
    }

    func testReplaceAndSelectAllThenTypeReplaceInsteadOfAppending() throws {
        for explicitReplace in [true, false] {
            let field = Field("AAA\n\nBBB")
            if !explicitReplace { XCTAssertTrue(try NativeTextInput.selectAll(field.driver())) }
            XCTAssertTrue(try NativeTextInput.type("CCC", replace: explicitReplace, driver: field.driver()))
            XCTAssertEqual(field.value, "CCC")
            XCTAssertEqual(field.writes, 1)
        }
    }

    func testUTF16SelectionPreservesUnselectedTextAndCaretInsertion() throws {
        let field = Field("a👩🏽‍💻z", selection: .init(location: 1, length: "👩🏽‍💻".utf16.count))
        XCTAssertTrue(try NativeTextInput.type("é\n", replace: false, driver: field.driver()))
        XCTAssertEqual(field.value, "aé\nz")
        XCTAssertFalse(try NativeTextInput.type("X", replace: false, driver: field.driver()))
        XCTAssertEqual(field.value, "aé\nz", "caret typing retains the normal key-event route")
    }

    func testEmptyReplaceClearsExistingText() throws {
        let field = Field("old text")
        XCTAssertTrue(try NativeTextInput.type("", replace: true, driver: field.driver()))
        XCTAssertEqual(field.value, "")
    }

    func testUnsupportedOrIgnoredSelectionNeverTypes() throws {
        for mode in ["unsupportedSelect", "unsupportedInsert", "ignoredSelect"] {
            let field = Field("preserve")
            field.ignoreSelect = mode == "ignoredSelect"
            let driver = field.driver(canSelect: mode != "unsupportedSelect", canInsert: mode != "unsupportedInsert")
            XCTAssertThrowsError(try NativeTextInput.type("new", replace: true, driver: driver))
            XCTAssertEqual(field.value, "preserve")
            XCTAssertEqual(field.writes, 0)
        }
    }

    func testIgnoredInsertionThrowsWithoutSyntheticRetry() {
        let field = Field("old", selection: .init(location: 0, length: 3))
        field.ignoreInsert = true
        XCTAssertThrowsError(try NativeTextInput.type("new", replace: false, driver: field.driver()))
        XCTAssertEqual(field.value, "old")
        XCTAssertEqual(field.writes, 1)
    }

    func testInvalidAndSplitSurrogateSelectionsRefuseBeforeWriting() {
        for range in [CFRange(location: -1, length: 1), .init(location: 0, length: -1),
                      .init(location: 4, length: Int.max), .init(location: Int.max, length: 1),
                      .init(location: 1, length: 1)] {
            let field = Field("😀abc", selection: range)
            XCTAssertThrowsError(try NativeTextInput.type("X", replace: false, driver: field.driver()))
            XCTAssertEqual(field.writes, 0)
        }
    }

    func testMultilineNormalizationAndSingleLineRefusal() throws {
        let field = Field("old")
        XCTAssertTrue(try NativeTextInput.type("a\r\nb\rc", replace: true, driver: field.driver()))
        XCTAssertEqual(field.value, "a\nb\nc")
        var singleLine = field.driver()
        singleLine.allowsMultiline = false
        XCTAssertThrowsError(try NativeTextInput.type("a\nb", replace: true, driver: singleLine))
        XCTAssertEqual(field.value, "a\nb\nc")
    }

    func testWebAndWrongWindowAncestryCannotQualifyNativeText() {
        struct Tree: AXAncestryProviding {
            let web: Bool
            func role(_ e: Int) -> String { e == 0 ? "AXTextArea" : e == 1 ? (web ? "AXWebArea" : "AXScrollArea") : "AXWindow" }
            func parent(_ e: Int) -> Int? { e < 2 ? e + 1 : nil }
            func windowID(_ e: Int) -> UInt32 { e == 2 ? 42 : 0 }
        }
        XCTAssertTrue(NativeTextInput.isNativeTextElement(0, inWindow: 42, provider: Tree(web: false)))
        XCTAssertFalse(NativeTextInput.isNativeTextElement(0, inWindow: 41, provider: Tree(web: false)))
        XCTAssertFalse(NativeTextInput.isNativeTextElement(0, inWindow: 42, provider: Tree(web: true)))
    }


    func testNonEditableSelectionsAndLargeCollapsedCaretKeepKeystrokeFallback() throws {
        let readonly = Field("scrollback", selection: .init(location: 0, length: 5))
        XCTAssertFalse(try NativeTextInput.type("ls\n", replace: false, driver: readonly.driver(canInsert: false)))
        XCTAssertEqual(readonly.writes, 0)
        let large = Field(String(repeating: "x", count: NativeTextInput.maximumDocumentBytes + 1))
        XCTAssertFalse(try NativeTextInput.type("x", replace: false, driver: large.driver()))
        large.selection = .init(location: 0, length: 5)
        XCTAssertFalse(try NativeTextInput.type("x", replace: false, driver: large.driver()))
        XCTAssertFalse(try NativeTextInput.selectAll(large.driver()))
        XCTAssertEqual(large.writes, 0)
        XCTAssertEqual(large.selections, 0)
    }

    func testReadbackErrorAfterInsertionIsAlwaysUnconfirmedAndNeverRetried() throws {
        let field = Field("old", selection: .init(location: 0, length: 3))
        var inserted = false
        let base = field.driver()
        let driver = NativeTextInput.Driver(canSelect: true, canInsert: true, value: {
            if inserted { throw SpaceOError.badRequest("focused target changed; edit refused") }
            return field.value
        }, selection: base.selection, select: base.select, insert: { text in
            try base.insert(text)
            inserted = true
        })
        XCTAssertThrowsError(try NativeTextInput.type("new", replace: false, driver: driver)) { error in
            XCTAssertTrue(error.localizedDescription.contains("delivery unconfirmed"))
            XCTAssertTrue(error.localizedDescription.contains("do not retry blindly"))
        }
        XCTAssertEqual(field.value, "new")
        XCTAssertEqual(field.writes, 1)
    }

    func testOnlyUnmodifiedCommandAUsesSemanticSelectAll() throws {
        XCTAssertTrue(NativeTextInput.isSelectAll(try KeyCombo.parse("cmd+a")))
        for key in ["a", "cmd+shift+a", "cmd+opt+a", "ctrl+a", "cmd+b"] {
            XCTAssertFalse(NativeTextInput.isSelectAll(try KeyCombo.parse(key)))
        }
    }
}
