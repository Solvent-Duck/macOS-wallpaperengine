import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ScriptSnapshotTests {
    @Test func sharedSnapshotsKeepScriptObjectsFreshAcrossModulesAndShutdown() throws {
        let host = ScriptHost()
        let source = """
        let previous;
        export function update() {
            const props = engine.userProperties;
            if (previous === props || (previous && previous.color.x !== 99))
                throw new Error('mutable script object reused');
            const value = props.color.add(1).x + props.mode;
            previous = props;
            props.color.x = 99;
            delete props.mode;
            return value;
        }
        """
        let first = SceneScriptUserProperties(["color": .vec3([2,3,4]), "mode": .int(1)])
        let equal = SceneScriptUserProperties(first.values)
        let changed = SceneScriptUserProperties(["color": .vec2([5,6]), "mode": .int(3)])
        for (snapshot, expected) in [(first,4.0), (first,4.0), (equal,4.0), (changed,9.0), (first,4.0)] {
            for module in ["a", "b"] {
                #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:],
                    instanceID: module, userProperties: snapshot) == .double(expected))
            }
        }
        host.shutdown()
        #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:],
            instanceID: "a", userProperties: first) == .double(4))
    }

    @Test func changedSnapshotsWithinOneFrameInvalidateResultsAndRetryFailures() throws {
        let host = ScriptHost()
        let source = """
        export function applyUserProperties(changed) {
            if (changed.mode === 2) throw new Error('invalid mode');
        }
        export function update(value) { return value + 2; }
        """
        let first = SceneScriptUserProperties(["mode": .int(1)])
        let invalid = SceneScriptUserProperties(["mode": .int(2)])
        let engine = SceneScriptEngineState(runtime: 0, screenResolution: RuntimeVector2(x: 100, y: 100), frameIndex: 0)
        func call(_ base: Int, _ snapshot: SceneScriptUserProperties) throws -> FrameValue {
            try host.evaluate(source: source, baseValue: .int(base), properties: [:],
                engine: engine, userProperties: snapshot)
        }
        #expect(try call(1, first) == .int(3))
        #expect(try call(1, SceneScriptUserProperties(first.values)) == .int(3))
        #expect(throws: ScriptHostError.self) { try call(10, invalid) }
        #expect(throws: ScriptHostError.self) { try call(10, invalid) }
        // Restore the base after a failure without advancing update twice.
        #expect(try call(1, first) == .int(1))
    }

    @Test func reusedInputJSONRestoresMutationsAndTracksCursorBatchChanges() throws {
        let host = ScriptHost()
        let source = """
        export function update() {
            const value = new Vec4(input.__hasCursor ? input.cursorPosition.x : -1,
                input.cursorWorldPosition.x, input.__cursorEvents.length, input.__resetCursorEvents ? 1 : 0);
            input.cursorPosition.x = 999;
            input.cursorWorldPosition.x = 999;
            input.__cursorEvents.push({});
            return value;
        }
        """
        let position = RuntimeVector2(x: 0.5, y: 0.5)
        let world = RuntimeVector2(x: 100, y: 100)
        let plain = SceneScriptInputState(cursorPosition: position, cursorWorldPosition: world)
        let event = SceneScriptCursorEvent(position: position, worldPosition: world, screenPosition: world, leftDown: true)
        let batch = SceneScriptInputState(cursorPosition: position, cursorWorldPosition: world,
            cursorEvents: [event], resetCursorEvents: true)
        let rows: [(SceneScriptInputState?, [Double])] = [
            (plain, [0.5,100,0,0]), (plain, [0.5,100,0,0]),
            (batch, [0.5,100,1,1]), (batch, [0.5,100,1,1]),
            (plain, [0.5,100,0,0]), (nil, [-1,0,0,0]), (nil, [-1,0,0,0])
        ]
        for (input, expected) in rows {
            #expect(try host.evaluate(source: source, baseValue: .vec4([0,0,0,0]), properties: [:],
                input: input) == .vec4(expected))
        }
    }
}
