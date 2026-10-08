import Foundation
import Testing
@testable import SteamLibrary

struct VDFTests {
    @Test func parsesNestedBlocksCaseInsensitively() throws {
        let vdf = try VDF.parse("""
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"/Users/me/Library/Application Support/Steam"
        \t\t"apps" { "431960" "0" }
        \t}
        }
        """)
        #expect(vdf["LibraryFolders"]?["0"]?["PATH"]?.string == "/Users/me/Library/Application Support/Steam")
        #expect(vdf["libraryfolders"]?["0"]?["apps"]?["431960"]?.string == "0")
        #expect(vdf["libraryfolders"]?["missing"] == nil)
    }

    @Test func handlesEscapesCommentsBareTokensAndConditionals() throws {
        let vdf = try VDF.parse("""
        // leading comment
        root {
            "quote" "say \\"hi\\"\\n"   // trailing comment
            bare value
            "mac" "1" [$OSX]
            "after" "ok"
        }
        """)
        #expect(vdf["root"]?["quote"]?.string == "say \"hi\"\n")
        #expect(vdf["root"]?["bare"]?.string == "value")
        #expect(vdf["root"]?["mac"]?.string == "1")
        #expect(vdf["root"]?["after"]?.string == "ok")
    }

    @Test func keepsOrderAndFirstDuplicate() throws {
        let vdf = try VDF.parse(#""r" { "b" "1" "a" "2" "b" "3" }"#)
        #expect(vdf["r"]?.entries.map(\.key) == ["b", "a", "b"])
        #expect(vdf["r"]?["b"]?.string == "1")
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: VDF.ParseError.self) { try VDF.parse(#""r" { "a" "1""#) }
        #expect(throws: VDF.ParseError.self) { try VDF.parse(#""r" "unterminated"#) }
        #expect(throws: VDF.ParseError.self) { try VDF.parse("}") }
        #expect(throws: VDF.ParseError.self) { try VDF.parse(#""dangling""#) }
    }
}
