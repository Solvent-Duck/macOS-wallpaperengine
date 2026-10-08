import Foundation
import Testing
@testable import WallpaperEngine

struct PropertyConditionTests {
    private typealias Value = PropertyCondition.Value

    private func check(_ source: String, _ values: [String: Value]) throws -> Bool {
        let condition = try #require(PropertyCondition(source), "failed to parse \(source)")
        return condition.isSatisfied { values[$0] ?? .undefined }
    }

    @Test func boolAndComboComparisons() throws {
        #expect(try check("clock.value == true", ["clock": .bool(true)]))
        #expect(try !check("clock.value == true", ["clock": .bool(false)]))
        #expect(try check("clock.value", ["clock": .bool(true)]))
        #expect(try check("!clock.value", ["clock": .bool(false)]))
        #expect(try check("music.value == 1 || music.value == 2", ["music": .number(2)]))
        #expect(try !check("music.value == 1 || music.value == 2", ["music": .number(3)]))
        #expect(try check("a.value == true && b.value != 0", ["a": .bool(true), "b": .number(4)]))
        #expect(try check("(a.value || b.value) && !c.value", ["b": .bool(true), "c": .bool(false)]))
        #expect(try check("size.value >= 25", ["size": .number(25)]))
        #expect(try !check("size.value < -1", ["size": .number(0)]))
    }

    @Test func javaScriptLooseEquality() throws {
        // Combo values are stored as strings; authors compare them to numbers and strings.
        #expect(try check("mode.value == 3", ["mode": .string("3")]))
        #expect(try check("mode.value == \"3\"", ["mode": .number(3)]))
        #expect(try check("mode.value == 'sync'", ["mode": .string("sync")]))
        #expect(try check("flag.value == 1", ["flag": .bool(true)]))
        #expect(try !check("mode.value == 'sync'", ["mode": .string("random")]))
    }

    @Test func authorTyposAndMissingProperties() throws {
        #expect(try check("raineffects.value=true", ["raineffects": .bool(true)]))
        #expect(try check("clock", ["clock": .bool(true)]))
        #expect(try !check("missing.value == true", [:]))
        #expect(try check("missing.value != true", [:]))
    }

    @Test func emptyOrUnparseableConditionsAreAlwaysVisible() {
        #expect(PropertyCondition("") == nil)
        #expect(PropertyCondition("   ") == nil)
        #expect(PropertyCondition("a.value ==") == nil)
        #expect(PropertyCondition("foo(bar)") == nil)
        #expect(PropertyCondition("a.b.c == 1") == nil)
        #expect(PropertyCondition("'unterminated") == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WE_PROPERTY_CORPUS_ROOT"] != nil))
    func everyCorpusConditionParses() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WE_PROPERTY_CORPUS_ROOT"]))
        var total = 0
        var failures: [String] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let properties = (json["general"] as? [String: Any])?["properties"] as? [String: Any] else { continue }
            for case let property as [String: Any] in properties.values {
                guard let condition = property["condition"] as? String,
                      !condition.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                total += 1
                if PropertyCondition(condition) == nil { failures.append(condition) }
            }
        }
        print("[PropertyConditionTests] parsed \(total - failures.count)/\(total) corpus conditions")
        #expect(total > 0)
        // Authored syntax errors stay visible by design.
        let malformedInSource: Set = ["circletype.value == 0 || bacgrkoundstyle.value == 1 ||"]
        #expect(Set(failures).subtracting(malformedInSource).isEmpty, "unparsed: \(Set(failures))")
    }
}
