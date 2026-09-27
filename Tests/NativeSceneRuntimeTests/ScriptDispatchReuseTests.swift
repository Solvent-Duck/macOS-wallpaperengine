import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ScriptDispatchReuseTests {
    @Test func bridgedUnicodeSourceKeepsLiveInputsAndRestartsAfterShutdown() throws {
        let host = ScriptHost()
        let text = """
        // 日本語 🌄
        let count = 0;
        export function update() { return ++count + engine.userProperties.amount + input.cursorPosition.x; }
        """
        let json = try JSONSerialization.data(withJSONObject: ["source": text])
        let source = try #require((JSONSerialization.jsonObject(with: json) as? [String: String])?["source"])
        func call(_ amount: Int, _ x: Float) throws -> FrameValue {
            try host.evaluate(source: source, baseValue: .int(0), properties: [:],
                input: SceneScriptInputState(cursorPosition: RuntimeVector2(x: x, y: 0)),
                instanceID: "unicode", userProperties: ["amount": .int(amount)])
        }
        #expect(try call(2, 3) == .int(6))
        #expect(try call(5, 7) == .int(14))
        host.shutdown()
        #expect(try call(2, 3) == .int(6))
    }

    @Test func failedTopLevelAndInitializationRetryAtTheirOwnLifetimes() throws {
        let host = ScriptHost()
        let source = """
        globalThis.attempts = (globalThis.attempts || 0) + 1;
        if (globalThis.attempts === 1) throw new Error('top-level retry');
        let initializationAttempts = 0;
        export function init() {
            if (++initializationAttempts === 1) throw new Error('init retry');
            return globalThis.attempts * 10 + initializationAttempts;
        }
        """
        func call() throws -> FrameValue {
            try host.evaluate(source: source, baseValue: .int(0), properties: [:], instanceID: "retry")
        }
        #expect(throws: ScriptHostError.self) { try call() }
        #expect(throws: ScriptHostError.self) { try call() }
        #expect(try call() == .int(22))
        #expect(try call() == .int(22))
    }

    @Test func newInstancesCompileAfterDispatcherReuseIncludingModulesWithoutUpdate() throws {
        let host = ScriptHost()
        func call(_ id: String, _ source: String) throws -> FrameValue {
            try host.evaluate(source: source, baseValue: .int(0), properties: [:], instanceID: id)
        }
        let first = "let n = 0; export function update() { return ++n; }"
        #expect(try call("first", first) == .int(1))
        #expect(try call("first", first) == .int(2))
        let late = "export function init() { return 37; }"
        #expect(try call("late", late) == .int(37))
        #expect(try call("late", late) == .int(37))
        // Source replacement already follows module lifetime: it takes effect
        // after destruction, not during an existing instance's evaluation.
        let replacement = "export function update() { return 99; }"
        #expect(try call("first", replacement) == .int(3))
        host.shutdown()
        #expect(try call("first", replacement) == .int(99))
    }
}
