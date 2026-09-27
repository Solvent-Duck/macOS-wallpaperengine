import CScriptHost
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct UserPropertyDeliveryTests {
    @Test func callbacksTrackValuesAndLateInstancesIndependently() throws {
        let host = ScriptHost()
        let source = """
        let calls = 0;
        export function applyUserProperties() { ++calls; }
        export function update() { return calls; }
        """
        func call(_ id: String, _ mode: Int, _ color: [Double] = [1,2,3]) throws -> FrameValue {
            try host.evaluate(source: source, baseValue: .int(0), properties: [:], instanceID: id,
                userProperties: ["mode": .int(mode), "color": .vec3(color)])
        }
        #expect(try call("first", 1) == .int(1))
        #expect(try call("first", 1) == .int(1))
        #expect(try call("late", 1) == .int(1))
        #expect(try call("first", 2) == .int(2))
        #expect(try call("first", 2, [3,2,1]) == .int(3))
        #expect(try call("late", 2, [3,2,1]) == .int(2))
        #expect(try call("first", 2, [3,2,1]) == .int(3))
    }

    @Test func callbackMutationsAreRestoredAndDeliveredOnTheNextEvaluation() throws {
        let host = ScriptHost()
        let source = """
        let calls = 0;
        export function applyUserProperties() {
            if (++calls === 1) engine.userProperties.mode = 9;
        }
        export function update() { return calls * 10 + engine.userProperties.mode; }
        """
        func call() throws -> FrameValue {
            try host.evaluate(source: source, baseValue: .int(0), properties: [:], userProperties: ["mode": .int(1)])
        }
        #expect(try call() == .int(19))
        #expect(try call() == .int(21))
        #expect(try call() == .int(21))
    }

    @Test func scriptsWithoutCallbacksStillReceiveFreshNestedProperties() throws {
        let host = ScriptHost()
        let source = """
        export function update() {
            const value = engine.userProperties.color.x;
            engine.userProperties.color.x = 99;
            delete engine.userProperties.mode;
            return value;
        }
        """
        for x: Double in [1,1,3,3] {
            #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:],
                userProperties: ["mode": .int(1), "color": .vec3([x,2,3])]) == .double(x))
        }
    }

    @Test func retainedReferencesStayIndependentAndVectorsKeepTheirMethods() throws {
        let host = ScriptHost()
        let source = """
        const startup = engine.userProperties;
        let previous;
        export function update() {
            if (startup === engine.userProperties || previous === engine.userProperties)
                throw new Error('property object reused');
            if (previous && previous.color.x !== 99)
                throw new Error('retained reference was overwritten');
            const value = engine.userProperties.color.add(1).x;
            previous = engine.userProperties;
            previous.color.x = 99;
            return value;
        }
        """
        for x: Double in [1,1,3,3] {
            #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:],
                userProperties: ["color": .vec3([x,2,3])]) == .double(x + 1))
        }
    }

    @Test func topLevelAndInitializationMutationsReceiveRestorationEvents() throws {
        let host = ScriptHost()
        let source = """
        engine.userProperties.mode = 8;
        let calls = 0;
        export function init() { engine.userProperties.mode = 9; }
        export function applyUserProperties() { ++calls; }
        export function update() { return calls * 10 + engine.userProperties.mode; }
        """
        for expected in [19,21,21] {
            #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:],
                userProperties: ["mode": .int(1)]) == .int(expected))
        }
    }

    @Test func failedCallbacksRetryAndRemovedKeysCanBeReintroduced() throws {
        let host = ScriptHost()
        let source = """
        let calls = 0;
        export function applyUserProperties() {
            if (++calls === 1) throw new Error('retry');
        }
        export function update() { return calls; }
        """
        func call(_ values: [String: FrameValue]) throws -> FrameValue {
            try host.evaluate(source: source, baseValue: .int(0), properties: [:], userProperties: values)
        }
        #expect(throws: ScriptHostError.self) { try call(["mode": .int(1)]) }
        #expect(try call(["mode": .int(1)]) == .int(2))
        #expect(try call([:]) == .int(2))
        #expect(try call(["mode": .int(1)]) == .int(3))
    }

    @Test func rawBridgeCallersWithoutARevisionKeepChangeDelivery() throws {
        let host = try #require(we_script_host_create())
        defer { we_script_host_destroy(host) }
        let source = "let calls=0; export function applyUserProperties() { ++calls; } export function update() { return calls; }"
        for (mode, count) in [(1,1),(1,1),(2,2),(2,2)] {
            let result = we_script_host_evaluate_json(host, "raw", source, "{}", "0",
                "{\"userProperties\":{\"mode\":\(mode)}}", "{}")
            defer { we_script_host_free_evaluation(result) }
            #expect(result.error_message == nil)
            #expect(String(cString: try #require(result.result_json)) == String(count))
        }
    }

    @Test func propertyTypesCanChangeAndReplayUsesFreshValues() throws {
        let host = ScriptHost()
        let source = """
        export function update() {
            const value = engine.userProperties.value;
            return value === null ? -1 : typeof value === 'number' ? value : value.add(1).x;
        }
        """
        for (input, expected): (FrameValue, Double) in [(.double(1),1), (.vec2([2,3]),3),
                (.vec2([2,3]),3), (.null,-1), (.vec3([4,5,6]),5), (.double(7),7)] {
            #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:],
                userProperties: ["value": input]) == .double(expected))
        }
        host.shutdown()
        #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:],
            userProperties: ["value": .vec4([8,9,10,11])]) == .double(9))
    }

    @Test func bridgeSnapshotCopiesNestedValuesAndPreservesExplicitOverrides() throws {
        let host = try #require(we_script_host_create())
        defer { we_script_host_destroy(host) }
        let snapshot = we_script_host_set_user_properties_json(host, "{\"items\":[{\"value\":2}],\"__proto__\":{\"own\":true}}")
        defer { we_script_host_free_evaluation(snapshot) }
        #expect(snapshot.error_message == nil)
        let source = """
        export function update() {
            const props = engine.userProperties;
            const value = props.items[0].value;
            props.items[0].value = 99;
            return value;
        }
        """
        for (engine, expected) in [("{}", "2"), ("{}", "2"),
            ("{\"userProperties\":{\"items\":[{\"value\":3}]}}", "3"), ("{}", "2")] {
            let result = we_script_host_evaluate_json(host, "snapshot", source, "{}", "0", engine, "{}")
            defer { we_script_host_free_evaluation(result) }
            #expect(result.error_message == nil)
            #expect(String(cString: try #require(result.result_json)) == expected)
        }
        let invalid = we_script_host_set_user_properties_json(host, "{")
        defer { we_script_host_free_evaluation(invalid) }
        #expect(invalid.error_message != nil)
        let result = we_script_host_evaluate_json(host, "snapshot", source, "{}", "0", "{}", "{}")
        defer { we_script_host_free_evaluation(result) }
        #expect(result.error_message == nil)
        #expect(String(cString: try #require(result.result_json)) == "2")
    }

    @Test func authoredPrototypeAccessorsCannotInterceptHostProperties() throws {
        let host = ScriptHost()
        let source = """
        export function update() {
            const value = engine.userProperties.mode;
            Object.defineProperty(Object.prototype, 'userProperties', {
                get() { throw new Error('host property getter intercepted'); },
                set() { throw new Error('host property setter intercepted'); },
                configurable: true
            });
            return value;
        }
        """
        for mode in [1,1,2,2] {
            #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:],
                userProperties: ["mode": .int(mode)]) == .int(mode))
        }
    }
}
