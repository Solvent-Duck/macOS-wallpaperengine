import Foundation
@testable import NativeSceneRuntime
import Testing

struct ScriptThreadMigrationTests {
    @Test func serializedHostPreservesScriptStateAcrossDifferentOSThreads() {
        let host = ScriptHost()
        let first = DispatchSemaphore(value: 1), second = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let results = MigrationResults()
        let source = "let ticks = 0; export function update() { return ++ticks; }"
        for (gate, next) in [(first, second), (second, first)] {
            Thread {
                for _ in 0..<4 {
                    guard gate.wait(timeout: .now() + 10) == .success else { results.append("timeout"); break }
                    do {
                        let value = try host.evaluate(source: source, baseValue: .double(0), properties: [:], instanceID: "migrating")
                        results.append(String(value.doubleValue ?? -1))
                    } catch { results.append(String(describing: error)) }
                    next.signal()
                }
                done.signal()
            }.start()
        }
        #expect(done.wait(timeout: .now() + 15) == .success)
        #expect(done.wait(timeout: .now() + 15) == .success)
        #expect(results.values == (1...8).map { String(Double($0)) })
    }

    @Test func recursionProtectionStillRejectsExcessiveCallsAndHostRecovers() throws {
        let host = ScriptHost()
        do {
            _ = try host.evaluate(source: "function recurse() { return 1 + recurse(); } export function update() { return recurse(); }",
                                  baseValue: .double(0), properties: [:], instanceID: "recursive")
            Issue.record("Unbounded recursion should throw")
        } catch { #expect(String(describing: error).localizedCaseInsensitiveContains("stack")) }
        #expect(try host.evaluate(source: "export function update() { return 7; }", baseValue: .double(0), properties: [:],
                                  instanceID: "recovery").doubleValue == 7)
    }
}

private final class MigrationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
}
