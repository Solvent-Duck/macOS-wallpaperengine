import CScriptHost
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ScriptEngineSnapshotTests {
    @Test func commonEngineInputsRemainFreshAndObserveResolutionAudioAndTimeChanges() throws {
        let host = ScriptHost()
        let source = """
        let previous;
        export function update() {
            if (previous === engine.screenResolution || (previous && previous.x !== 999))
                throw new Error('engine vector reused');
            const result = new Vec4(engine.runtime, engine.screenResolution.x, engine.canvasSize.y,
                engine.audioLeft[0] + engine.audioRight[0]);
            previous = engine.screenResolution;
            previous.x = 999;
            engine.audioLeft[0] = 999;
            return result;
        }
        """
        let first = SceneScriptEngineState(runtime: 1, screenResolution: RuntimeVector2(x: 100, y: 100),
            canvasSize: RuntimeVector2(x: 200, y: 200))
        let changed = SceneScriptEngineState(runtime: 2, screenResolution: RuntimeVector2(x: 300, y: 300),
            canvasSize: RuntimeVector2(x: 400, y: 400))
        let rows: [(SceneScriptEngineState, [Float], [Double])] = [
            (first, [1,2,3,4], [1,100,200,4]), (first, [1,2,3,4], [1,100,200,4]),
            (changed, [5,6,7,8], [2,300,400,12]), (changed, [9,10,11,12], [2,300,400,20])
        ]
        for (engine, audio, expected) in rows {
            for module in ["a", "b"] {
                #expect(try host.evaluate(source: source, baseValue: .vec4([0,0,0,0]), properties: [:],
                    engine: engine, audioSpectrum: audio, instanceID: module) == .vec4(expected))
            }
        }
        host.shutdown()
        #expect(try host.evaluate(source: source, baseValue: .vec4([0,0,0,0]), properties: [:],
            engine: first, audioSpectrum: [1,2,3,4], instanceID: "a") == .vec4([1,100,200,4]))
    }

    @Test func absentEngineDoesNotInheritAnotherModulesCachedFrame() throws {
        let host = ScriptHost()
        let source = "export function update() { return engine.runtime; }"
        let engine = SceneScriptEngineState(runtime: 7, screenResolution: RuntimeVector2(x: 100, y: 100))
        #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:],
            engine: engine, instanceID: "with-frame") == .double(7))
        #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:],
            instanceID: "without-frame") == .double(0))
        #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:],
            engine: engine, instanceID: "with-frame") == .double(7))
    }

    @Test func privateBridgeSnapshotPreservesOverridesAndSurvivesRejectedReplacements() throws {
        let host = try #require(we_script_host_create())
        defer { we_script_host_destroy(host) }
        let snapshot = we_script_host_set_engine_snapshot_json(host,
            "{\"runtime\":1,\"audioLeft\":[2],\"extra\":{\"value\":3},\"__proto__\":{\"own\":true}}")
        defer { we_script_host_free_evaluation(snapshot) }
        #expect(snapshot.error_message == nil)
        let source = """
        export function update() {
            if (!Object.prototype.hasOwnProperty.call(engine, '__proto__') || !engine.__proto__.own)
                throw new Error('own data member lost');
            const result = engine.runtime + engine.audioLeft[0] + engine.extra.value;
            engine.audioLeft[0] = 99;
            engine.extra.value = 99;
            Object.defineProperty(Object.prototype, 'runtime', {
                get() { throw new Error('inherited getter intercepted'); },
                set() { throw new Error('inherited setter intercepted'); }, configurable: true
            });
            return result;
        }
        """
        func read(_ overrides: String = "{}") throws -> String {
            let result = we_script_host_evaluate_json(host, "raw", source, "{}", "0", overrides, "{}")
            defer { we_script_host_free_evaluation(result) }
            #expect(result.error_message == nil)
            return String(cString: try #require(result.result_json))
        }
        #expect(try read() == "6")
        #expect(try read() == "6")
        #expect(try read("{\"runtime\":10}") == "15")
        #expect(try read("{\"extra\":{\"value\":4}}") == "7")
        for invalid in ["{", "[]", "null"] {
            let result = we_script_host_set_engine_snapshot_json(host, invalid)
            defer { we_script_host_free_evaluation(result) }
            #expect(result.error_message != nil)
            #expect(try read() == "6")
        }
    }
}
