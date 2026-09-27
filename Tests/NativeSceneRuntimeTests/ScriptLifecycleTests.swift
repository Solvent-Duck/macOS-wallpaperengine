import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ScriptLifecycleTests {
    @Test func consoleErrorsReportAuthoredProblemsWithoutAbortingTheScript() throws {
        let host = ScriptHost()
        let source = """
        export function update() {
            console.log('info', 3, false);
            console.error('missing optional event', null, {toString() { return 'detail'; }});
            return 7;
        }
        """
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(7))
    }

    @Test func scriptFailuresIncludeTheirCallChainAndOwner() throws {
        let host = ScriptHost()
        let source = """
        function missingFeature() { throw new Error('unsupported feature'); }
        function sharedHelper() { missingFeature(); }
        export function update() { sharedHelper(); }
        """
        do {
            _ = try host.evaluate(source: source, baseValue: .int(0), properties: [:], instanceID: "diagnostic-owner")
            Issue.record("Expected the authored error")
        } catch {
            let message = error.localizedDescription
            #expect(message.hasPrefix("Error: unsupported feature"))
            #expect(message.contains("missingFeature"))
            #expect(message.contains("sharedHelper"))
            #expect(message.contains("diagnostic-owner"))
        }
        #expect(try host.evaluate(source: "export function update() { return 7; }", baseValue: .int(0), properties: [:]) == .int(7))
    }

    @Test func throwingStackAccessorsDoNotMaskErrorsOrPoisonLaterEvaluations() throws {
        let host = ScriptHost()
        do {
            _ = try host.evaluate(source: "export function update() { const error = new Error('original'); Object.defineProperty(error, 'stack', {get() { throw new Error('getter'); }}); throw error; }",
                                  baseValue: .int(0), properties: [:], instanceID: "throwing-stack")
            Issue.record("Expected the authored error")
        } catch { #expect(error.localizedDescription == "Error: original") }
        #expect(try host.evaluate(source: "export function update() { return 9; }", baseValue: .int(0), properties: [:]) == .int(9))
    }

    @Test func repeatedFrameReadsRespectChangedInputsAndRetryFailures() throws {
        let host = ScriptHost()
        let source = """
        const props = createScriptProperties().addSlider({name:'step',value:1}).finish();
        export function applyUserProperties(changed) {
            if (changed.mode === 2) throw new Error('invalid mode');
        }
        export function update(value) { return value + props.step; }
        """
        func value(_ base: Int, _ step: Int, _ mode: Int, _ frame: UInt64 = 0) throws -> FrameValue {
            try host.evaluate(source: source, baseValue: .int(base), properties: ["step": .int(step)],
                engine: engine(frame), userProperties: ["mode": .int(mode)])
        }
        #expect(try value(1, 2, 1) == .int(3))
        #expect(try value(1, 2, 1) == .int(3))
        #expect(throws: ScriptHostError.self) { try value(10, 4, 2) }
        // The failed property event changed the base before throwing. A read
        // of the original inputs must restore it without running update twice.
        #expect(try value(1, 2, 1) == .int(1))
        #expect(try value(10, 4, 1) == .int(10))
        #expect(try value(10, 4, 1, 1) == .int(14))
    }

    @Test func failedUpdatesRetryAndUnframedCallsContinueAdvancing() throws {
        let host = ScriptHost()
        let source = "let count = 0; export function update() { if (++count < 2) throw new Error('retry'); return count; }"
        #expect(throws: ScriptHostError.self) {
            try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine(0))
        }
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine(0)) == .int(2))
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine(0)) == .int(2))
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(3))
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(4))
    }

    @Test func authoredLocalsCannotShadowHostPropertyInitialization() throws {
        let host = ScriptHost()
        let source = """
        export var scriptProperties = createScriptProperties().addSlider({name:'amount',value:2}).finish();
        let state = 10;
        const copy = value => value + 100;
        const __props = {amount:1000};
        export function update() { return ++state + scriptProperties.amount + copy(0); }
        """
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine(0)) == .int(113))
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: ["amount": .int(3)], engine: engine(1)) == .int(115))
    }

    @Test func authoredCallbackLocalsRemainSeparateFromPreludeVariables() throws {
        let host = ScriptHost()
        let source = """
        const key = 'private';
        const engine = {privateValue:0.5};
        const state = 0.25;
        export function init() { thisObject.alpha = state + engine.privateValue; }
        export function applyUserProperties() { thisObject.alpha += state; }
        """
        let initialized = try host.executeSceneCallback(source: source, callback: .initialize,
            thisObject: ["alpha": .double(0)], changedUserProperties: [:], engine: engine(0),
            input: SceneScriptInputState(cursorPosition: nil))
        #expect(initialized["alpha"] == .double(0.75))
        let updated = try host.executeSceneCallback(source: source, callback: .applyUserProperties,
            thisObject: initialized, changedUserProperties: [:], engine: engine(1),
            input: SceneScriptInputState(cursorPosition: nil))
        #expect(updated["alpha"]?.doubleValue == 1)
    }

    @Test(arguments: ["\u{00a0}", "\u{1680}", "\u{2003}", "\u{2028}", "\u{2029}", "\u{202f}", "\u{205f}", "\u{3000}", "\u{feff}"])
    func unicodeWhitespaceSeparatesModuleDeclarations(space: String) throws {
        let source = "import\(space)*\(space)as\(space)数学\(space)from\(space)'WEMath';export\(space)let\(space)value=数学.clamp(9,0,3);export\(space)function\(space)update(){return value;}"
        #expect(try ScriptHost().evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(3))
    }

    @Test func unicodeLineSeparatorsTerminateCommentsWithoutEditingLiterals() throws {
        let source = "// export a comment\u{2028}import*as math from'WEMath';const text='a\u{00a0}b';// second comment\r export function update(){return text.length+math.clamp(8,0,2);}"
        #expect(try ScriptHost().evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(5))
    }

    @Test func minifiedNamespaceImportsKeepAliasesAndAreAvailableBeforeTheirDeclaration() throws {
        let source = "let initial=math.clamp(9,0,3);import*as math from'WEMath';export function update(){return initial+math.clamp(-1,2,5);}"
        #expect(try ScriptHost().evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(5))
    }

    @Test func multilineNamedImportsSupportAliasesAndTrailingCommas() throws {
        let source = """
        import {
            clamp as limit,
            mix,
        } from 'WEMath';
        export function update() { return limit(mix(2, 6, 0.5), 0, 3); }
        """
        #expect(try ScriptHost().evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(3))
    }

    @Test func moduleRewritingPreservesStringsCommentsRegexAndNestedTemplates() throws {
        let source = #"""
        // import * as missing from 'unknown'; export function phantom() {}
        const text = "export function import*as math from'WEMath'";
        const nested = `outer ${`export function ${'import from'}`}`;
        const pattern = /export function/;
        /* export function missing() { import * as x from 'unknown'; } */
        export function update() {
            return text.startsWith('export function') && pattern.test(text)
                && nested === 'outer export function import from';
        }
        """#
        #expect(try ScriptHost().evaluate(source: source, baseValue: .bool(false), properties: [:]) == .bool(true))
    }

    @Test func namespaceImportsAlsoWorkInSceneCallbacks() throws {
        let host = ScriptHost()
        let source = "import*as math from'WEMath';export function init(){thisObject.alpha=math.clamp(2,0,0.5);}"
        let value = try host.executeSceneCallback(source: source, callback: .initialize, thisObject: ["alpha": .double(1)], changedUserProperties: [:], engine: engine(0), input: SceneScriptInputState(cursorPosition: nil))
        #expect(value["alpha"] == .double(0.5))
    }

    @Test func garbageCollectionDuringMappedArgumentsKeepsActiveStackReferencesValid() throws {
        let host = ScriptHost()
        let source = """
        function pressure(value) {
            const args = arguments;
            let last;
            for (let i = 0; i < 100000; i++) last = new Array(40).fill({index: i});
            return args[0] + last[0].index;
        }
        export function update() { return pressure(7); }
        """
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:]) == .int(100006))
    }

    private func engine(_ frame: UInt64, time: Double? = nil) -> SceneScriptEngineState {
        SceneScriptEngineState(runtime: time ?? Double(frame) / 60,
                               screenResolution: RuntimeVector2(x: 1280, y: 720),
                               frametime: 1 / 60, frameIndex: frame)
    }

    @Test func initStateAndCurrentValuePersistWithOnlyOneUpdatePerFrame() throws {
        let host = ScriptHost()
        let source = """
        let initial;
        let count = 0;
        export function init(value) { initial = value.copy(); }
        export function update(value) {
            count++;
            return value.add(new Vec3(0, initial.y, count));
        }
        """
        let first = try host.evaluate(source: source, baseValue: .vec3([2, 3, 0]), properties: [:], engine: engine(0))
        #expect(first == .vec3([2, 6, 1]))
        #expect(try host.evaluate(source: source, baseValue: .vec3([2, 3, 0]), properties: [:], engine: engine(0)) == first)
        #expect(try host.evaluate(source: source, baseValue: .vec3([2, 3, 0]), properties: [:], engine: engine(1)) == .vec3([2, 9, 3]))
    }

    @Test func identicalSourcesHaveIndependentPropertyInstancesAndSceneStorage() throws {
        let host = ScriptHost()
        let otherScene = ScriptHost()
        let source = "let count = 0; export function update() { shared.total = (shared.total || 0) + 1; return ++count * 10 + shared.total; }"
        func value(_ session: ScriptHost, _ id: String, _ frame: UInt64) throws -> FrameValue {
            try session.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine(frame), instanceID: id)
        }
        #expect(try value(host, "left", 0) == .int(11))
        #expect(try value(host, "right", 0) == .int(12))
        #expect(try value(host, "left", 1) == .int(23))
        #expect(try value(otherScene, "left", 0) == .int(11))
    }

    @Test func retainedAudioBuffersUpdateInPlaceAndClearOnSilence() throws {
        let host = ScriptHost()
        let source = """
        const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
        const left = audio.left;
        export function update() { return new Vec3(left[0], audio.right[0], audio.average[0]); }
        """
        let sound = [Float](repeating: 0.25, count: 64) + [Float](repeating: 0.75, count: 64)
        #expect(try host.evaluate(source: source, baseValue: .vec3([0, 0, 0]), properties: [:], engine: engine(0), audioSpectrum: sound)
                == .vec3([0.25, 0.75, 0.5]))
        #expect(try host.evaluate(source: source, baseValue: .vec3([0, 0, 0]), properties: [:], engine: engine(1)) == .vec3([0, 0, 0]))
    }

    @Test func numericInitializationReturnsBecomeVectorsBeforeTheFirstUpdate() throws {
        let host = ScriptHost()
        let source = "export function init(value) { return 2; } export function update(value) { return value.add(new Vec3(0, 1, 0)); }"
        #expect(try host.evaluate(source: source, baseValue: .vec3([1, 1, 1]), properties: [:], engine: engine(0)) == .vec3([2, 3, 2]))
        #expect(try host.evaluate(source: source, baseValue: .vec3([1, 1, 1]), properties: [:], engine: engine(1)) == .vec3([2, 4, 2]))
        #expect(!host.isSceneCallbackScript("export function init(value) { return value.multiply(2); }"))
    }

    @Test func timersUseMillisecondsAndReturnCancellationFunctions() throws {
        let host = ScriptHost()
        let source = """
        let value = 0;
        let cancel;
        export function init() {
            engine.setTimeout(() => value += 100, 100);
            const cancelled = engine.setTimeout(() => value += 1000, 50);
            cancelled();
            cancel = engine.setInterval(() => { value++; if (value >= 102) cancel(); }, 50);
        }
        export function update() { return value; }
        """
        for (index, pair) in [(0.0, 0), (0.049, 0), (0.050, 1), (0.1, 102), (0.2, 102)].enumerated() {
            #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine(UInt64(index), time: pair.0)) == .int(pair.1))
        }
    }

    @Test func scriptPropertiesAndUserPropertyEventsUpdateWithoutReinitializing() throws {
        let host = ScriptHost()
        let source = """
        var props = createScriptProperties().addSlider({name:'speed', value:1}).finish();
        let initializations = 0;
        let userValue = 0;
        export function init() { initializations++; }
        export function applyUserProperties(changed) { if ('value' in changed) userValue = changed.value; }
        export function update() { return initializations * 100 + props.speed * 10 + userValue; }
        """
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine(0), userProperties: ["value": .int(3)]) == .int(113))
        #expect(try host.evaluate(source: source, baseValue: .int(0), properties: ["speed": .int(2)], engine: engine(1), userProperties: ["value": .int(4)]) == .int(124))
    }

    @Test func topLevelCodeReceivesVectorPropertiesAndDeviceFunctions() throws {
        let host = ScriptHost()
        let source = """
        const props = createScriptProperties().addColor({name:'color', value:new Vec3(1)}).finish();
        const initial = props.color.copy();
        const canvas = engine.canvasSize.divide(2);
        const isDesktop = engine.isDesktopDevice() && !engine.isMobileDevice() && engine.isWallpaper()
            && !engine.isScreensaver() && !engine.isRunningInEditor() && engine.isLandscape() && !engine.isPortrait();
        export function update() { return new Vec3(canvas.x, initial.y, isDesktop ? 1 : 0); }
        """
        #expect(try host.evaluate(source: source, baseValue: .vec3([0, 0, 0]), properties: ["color": .vec3([0.25, 0.5, 0.75])], engine: engine(0)) == .vec3([640, 0.5, 1]))
    }

    @Test func anExceptionDoesNotResetOtherInstances() throws {
        let host = ScriptHost()
        let good = "let count = 0; export function update() { return ++count; }"
        for frame in 0..<100 {
            #expect(throws: ScriptHostError.self) {
                try host.evaluate(source: "export function update() { throw new Error('isolated failure'); }",
                                  baseValue: .int(0), properties: [:], engine: engine(UInt64(frame)), instanceID: "bad")
            }
            #expect(try host.evaluate(source: good, baseValue: .int(0), properties: [:], engine: engine(UInt64(frame)), instanceID: "good") == .int(frame + 1))
        }
    }

    @Test func shutdownCallsDestroyOnceWithTheRetainedLocalState() throws {
        let host = ScriptHost()
        let source = "let count = 0; export function update() { return ++count; } export function destroy() { shared.destroyed = (shared.destroyed || 0) + count; }"
        _ = try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine(0))
        _ = try host.evaluate(source: source, baseValue: .int(0), properties: [:], engine: engine(1))
        host.shutdown()
        host.shutdown()
        #expect(try host.evaluate(source: "export function update() { return shared.destroyed; }", baseValue: .int(0), properties: [:]) == .int(2))
    }

    @Test func imperativeCallbacksRetainStateForEachOwner() throws {
        let host = ScriptHost()
        let source = "let initial; export function init() { initial = thisObject.alpha; } export function applyUserProperties(props) { thisObject.alpha = initial * props.factor; }"
        let input = SceneScriptInputState(cursorPosition: nil)
        for (id, alpha) in [("left", 2), ("right", 3)] {
            _ = try host.executeSceneCallback(source: source, callback: .initialize,
                thisObject: ["alpha": .int(alpha)], changedUserProperties: [:], engine: engine(0), input: input, instanceID: id)
        }
        for (id, expected) in [("left", 8), ("right", 12)] {
            let result = try host.executeSceneCallback(source: source, callback: .applyUserProperties,
                thisObject: ["alpha": .int(0)], changedUserProperties: ["factor": .int(4)], engine: engine(1), input: input, instanceID: id)
            #expect(result["alpha"] == .int(expected))
        }
    }

    @Test func sceneRuntimeKeepsLayerScriptsIndependentAndDoesNotFreezeCallbackOwners() throws {
        let source = "let count = 0; export function init() {} export function update(value) { return value.add(new Vec3(++count, 0, 0)); }"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WEScriptLifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let objects = [10, 30].enumerated().map { index, x -> [String: Any] in
            ["id": index + 1, "image": "missing.json",
             "origin": ["value": "\(x) 20 0", "script": source],
             "alpha": ["value": 1, "script": "export function init() { thisObject.alpha = 0.5; }"],
             "visible": ["value": true, "script": "export function init() { thisObject.visible = false; }"]]
        }
        try JSONSerialization.data(withJSONObject: ["type": "scene", "file": "scene.json"]).write(to: root.appendingPathComponent("project.json"))
        try JSONSerialization.data(withJSONObject: ["camera": [:], "general": [:], "objects": objects]).write(to: root.appendingPathComponent("scene.json"))
        let scene = try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
        let runtime = SceneRuntime(scene: scene)
        let first = runtime.step(deltaTime: 1 / 60)
        #expect(first.nodes.map { $0.worldPosition.x } == [11, 31])
        #expect(first.nodes.map { $0.opacity } == [0.5, 0.5])
        #expect(first.nodes.allSatisfy { !$0.visible })
        #expect(runtime.step(deltaTime: 1 / 60).nodes.map { $0.worldPosition.x } == [13, 33])
        runtime.setPaused(true)
        #expect(runtime.step(deltaTime: 10).nodes.map { $0.worldPosition.x } == [13, 33])
        #expect(runtime.step(deltaTime: 10).nodes.map { $0.worldPosition.x } == [13, 33])
        runtime.setPaused(false)
        #expect(runtime.step(deltaTime: 1 / 60).nodes.map { $0.worldPosition.x } == [16, 36])
        let otherRuntime = SceneRuntime(scene: scene)
        #expect(otherRuntime.step(deltaTime: 1 / 60).nodes.map { $0.worldPosition.x } == [11, 31])
    }
}
