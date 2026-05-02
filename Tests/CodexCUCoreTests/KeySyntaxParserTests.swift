import Testing
@testable import CodexCUCore

@Test func testParseSimpleKey() throws {
    let parser = KeySyntaxParser()
    let result = try parser.parse("Return")
    #expect(result.keyCode == 36)  // kVK_Return
    #expect(result.modifiers.isEmpty)
}

@Test func testParseModifierKey() throws {
    let parser = KeySyntaxParser()
    let result = try parser.parse("super+c")
    #expect(result.keyCode == 8)  // kVK_ANSI_C
    #expect(result.modifiers.contains(.maskCommand))
}

@Test func testParseMultiModifier() throws {
    let parser = KeySyntaxParser()
    let result = try parser.parse("ctrl+shift+a")
    #expect(result.keyCode == 0)  // kVK_ANSI_A
    #expect(result.modifiers.contains(.maskControl))
    #expect(result.modifiers.contains(.maskShift))
}
