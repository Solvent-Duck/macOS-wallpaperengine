import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

@Suite(.serialized)
struct CursorEventTests {
    @Test func omittedInteractionFlagStillReceivesAuthoredCallbacks() throws {
        let scene = try fixture(script: "export function cursorDown() { shared.trace = 'pressed'; }", target: ["solid": NSNull()])
        #expect(scene.nodes.first?.solid == nil)
        let runtime = SceneRuntime(scene: scene), center = RuntimeVector2(x: 0.5, y: 0.5)
        _ = runtime.step(deltaTime: 0, cursorPosition: center)
        #expect(runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true).texts.first?.content == "pressed")
    }

    @Test func clicksDispatchInOrderAndKeepPropertyContext() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        let trace = [];
        function record(name, e) {
            if (!(e.worldPosition instanceof Vec3) || !(e.localPosition instanceof Vec3)) throw Error('event vectors');
            if (thisLayer.name !== 'target') throw Error('wrong layer');
            trace.push(name);
            shared.trace = trace.join(',');
        }
        export function cursorEnter(e) { record('enter', e); }
        export function cursorLeave(e) { record('leave', e); }
        export function cursorMove(e) { record('move', e); }
        export function cursorDown(e) { record('down', e); }
        export function cursorUp(e) { record('up', e); }
        export function cursorClick(e) { record('click', e); }
        """))
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.1, y: 0.5))
        let entered = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5))
        #expect(entered.texts.first?.content == "enter,move")
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5), cursorLeftDown: true)
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5), cursorLeftDown: true)
        let released = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5))
        #expect(released.texts.first?.content == "enter,move,down,up,click")
    }

    @Test func authoredDragMovesTheLayerAndReleasesOutsideItsOldBounds() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        let dragging = false, offset;
        export function cursorDown(e) { dragging = true; offset = thisLayer.origin.subtract(e.worldPosition); }
        export function cursorMove(e) { if (dragging) thisLayer.origin = e.worldPosition.add(offset); }
        export function cursorUp(e) { dragging = false; shared.trace = 'released'; }
        """))
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5))
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5), cursorLeftDown: true)
        let moved = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.95, y: 0.85), cursorLeftDown: true)
        #expect(moved.nodes.first?.worldPosition == RuntimeVector3(x: 190, y: 85, z: 0))
        let released = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.95, y: 0.85))
        #expect(released.texts.first?.content == "released")
        let stationary = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.2, y: 0.1))
        #expect(stationary.nodes.first?.worldPosition == RuntimeVector3(x: 190, y: 85, z: 0))
    }

    @Test(arguments: ["nonsolid", "hidden", "hidden-parent", "zero-scale"])
    func ineligibleLayersIgnoreInput(reason: String) throws {
        let script = "export function init() { shared.trace = 'ready'; } export function cursorDown() { shared.trace = 'bad'; }"
        var target: [String: Any] = [:], additional: [[String: Any]] = []
        switch reason {
        case "nonsolid": target["solid"] = false
        case "hidden": target["visible"] = ["value": false, "script": script]
        case "hidden-parent":
            target["parent"] = 3
            additional = [["id": 3, "name": "parent", "visible": false]]
        default: target["scale"] = "0 0 0"
        }
        let runtime = SceneRuntime(scene: try fixture(script: script, target: target, additional: additional))
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5))
        let frame = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5), cursorLeftDown: true)
        #expect(frame.texts.first?.content == "ready")
    }

    @Test func localCoordinatesFollowRotatedScaledParentAndAlignment() throws {
        let scene = try fixture(script: """
        export function cursorDown(e) { shared.trace = [Math.round(e.localPosition.x),Math.round(e.localPosition.y),Math.round(e.worldPosition.x),Math.round(e.worldPosition.y)].join(','); }
        """, target: ["parent": 3, "origin": "10 0 0", "scale": "0.5 0.5 1", "alignment": "bottomleft"],
            additional: [["id": 3, "name": "parent", "origin": "120 20 0", "scale": "2 2 1", "angles": "0 0 \(Double.pi / 2)"]])
        let runtime = SceneRuntime(scene: scene)
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.8))
        let frame = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.8), cursorLeftDown: true)
        #expect(frame.texts.first?.content == "40,20,100,80")
    }

    @Test func releaseOutsideCancelsClickAndAbsentInputClearsCapture() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        export function init() { shared.trace = ''; }
        export function cursorUp() { shared.trace += 'up'; }
        export function cursorClick() { shared.trace += 'click'; }
        """))
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5))
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5), cursorLeftDown: true)
        let outside = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0, y: 0))
        #expect(outside.texts.first?.content == "up")
        _ = runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5), cursorLeftDown: true)
        #expect(runtime.step(deltaTime: 0).texts.first?.content == "upup")
        #expect(runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.5, y: 0.5)).texts.first?.content == "upup")
    }

    @Test func pauseAndShutdownDoNotReplayHeldClicks() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        export function init() { shared.trace = ''; }
        export function cursorClick() { shared.trace += 'click'; }
        """))
        let center = RuntimeVector2(x: 0.5, y: 0.5)
        _ = runtime.step(deltaTime: 0, cursorPosition: center)
        _ = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        runtime.setPaused(true)
        _ = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        runtime.setPaused(false)
        #expect(runtime.step(deltaTime: 0, cursorPosition: center).texts.first?.content == "")
        _ = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        #expect(runtime.step(deltaTime: 0, cursorPosition: center).texts.first?.content == "click")
        runtime.shutdown()
        #expect(runtime.step(deltaTime: 0, cursorPosition: center).texts.first?.content == "")
    }

    @Test func everyPropertyModuleReceivesTheSameHitAndItsOwnContext() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        export function cursorDown() { shared.trace += 'visible'; }
        """, target: ["alpha": ["value": 1, "script": """
        export function init() { shared.trace = ''; }
        export function cursorDown() { shared.trace += 'alpha'; thisLayer.origin = new Vec3(190,90,0); }
        """]]))
        let center = RuntimeVector2(x: 0.5, y: 0.5)
        _ = runtime.step(deltaTime: 0, cursorPosition: center)
        let frame = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        #expect(frame.texts.first?.content == "alphavisible")
        #expect(frame.nodes.first?.worldPosition == RuntimeVector3(x: 190, y: 90, z: 0))
    }

    @Test func interactionFlagSurvivesSerializationSeparatelyFromSolidModel() throws {
        let scene = try fixture(script: "", target: ["solid": false])
        let decoded = try JSONDecoder().decode(SceneDescription.self, from: JSONEncoder().encode(scene))
        #expect(decoded.nodes.first?.solid == false)
        #expect(decoded.nodes.first?.image?.model?.solidLayer == true)
    }

    @Test func textHitBoundsUseTheLiveMeasuredSize() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        export function cursorDown(e) {
            const s = thisLayer.size;
            shared.trace = Math.abs(e.localPosition.x-s.x/2)<0.001 && Math.abs(e.localPosition.y-s.y/2)<0.001 ? 'center' : 'wrong bounds';
        }
        """, target: ["text": "Click", "pointsize": 8, "horizontalalign": "center", "verticalalign": "center"]))
        let center = RuntimeVector2(x: 0.5, y: 0.5)
        _ = runtime.step(deltaTime: 0, cursorPosition: center)
        let frame = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        #expect(frame.texts.first(where: { $0.nodeID.rawValue == 2 })?.content == "center")
    }

    @Test func callbackFailureDoesNotReplayThePressOrPreventLaterRelease() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        export function init() { shared.trace = ''; }
        export function cursorDown() { shared.trace += 'down'; throw Error('expected cursor failure'); }
        export function cursorUp() { shared.trace += 'up'; }
        """))
        let center = RuntimeVector2(x: 0.5, y: 0.5)
        _ = runtime.step(deltaTime: 0, cursorPosition: center)
        _ = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        _ = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        #expect(runtime.step(deltaTime: 0, cursorPosition: center).texts.first?.content == "downup")
    }

    @Test func createdLayersReceiveEventsAndDestroyedLayersStopReceivingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WECursorCreated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let child: [String: Any] = ["name": "created", "image": "model.json", "solid": true,
            "origin": "100 50 0", "size": "80 40", "visible": ["value": true, "script": """
            export function cursorDown() { shared.trace = 'created'; thisLayer.origin = new Vec3(150,50,0); thisScene.destroyLayer(thisLayer); }
            """]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: child), as: UTF8.self)
        let runtime = SceneRuntime(scene: try fixture(script:
            "export function init() { thisScene.createLayer(\(json)); }", target: ["solid": false], root: root), assetRoots: [root])
        let center = RuntimeVector2(x: 0.5, y: 0.5)
        _ = runtime.step(deltaTime: 0, cursorPosition: center)
        let clicked = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        #expect(clicked.nodes.first(where: { $0.name == "created" })?.worldPosition == RuntimeVector3(x: 150, y: 50, z: 0))
        let removed = runtime.step(deltaTime: 0, cursorPosition: center)
        // The original reporter runs before the appended dynamic module.
        #expect(removed.texts.first?.content == "created")
        #expect(!removed.nodes.contains(where: { $0.name == "created" }))
    }

    private func fixture(script: String, target: [String: Any] = [:], additional: [[String: Any]] = [], root retainedRoot: URL? = nil) throws -> SceneDescription {
        let root = retainedRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("WECursorEvents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if retainedRoot == nil { try? FileManager.default.removeItem(at: root) } }
        var object: [String: Any] = ["id": 1, "name": "target", "image": "model.json", "solid": true,
            "origin": "100 50 0", "size": "80 40", "visible": ["value": true, "script": script]]
        object.merge(target, uniquingKeysWith: { _, value in value })
        if object["solid"] is NSNull { object.removeValue(forKey: "solid") }
        if target["text"] != nil { object.removeValue(forKey: "image") }
        let reporter: [String: Any] = ["id": 2, "name": "reporter", "text": ["value": "", "script":
            "export function update() { return shared.trace || ''; }"], "origin": "0 0 0", "pointsize": 8]
        for (name, value) in [
            "project.json": ["type": "scene", "file": "scene.json"],
            "model.json": ["width": 80, "height": 40, "solidlayer": true, "material": "material.json"],
            "material.json": ["passes": []],
            "scene.json": ["camera": [:], "general": ["orthogonalprojection": ["width": 200, "height": 100]], "objects": additional + [object, reporter]]
        ] as [String: Any] {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
        }
        return try SceneDescriptionLoader.loadSceneDescription(wallpaperPath: root.path, assetsPath: root.path)
    }
}

extension CursorEventTests {
    @Test func betweenFrameDragRunsCallbacksButOnlyOneUpdate() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        let dragging = false, offset, updates = 0;
        export function init() { shared.events = ''; }
        export function cursorDown(e) { shared.events += 'D'; dragging = true; offset = thisLayer.origin.subtract(e.worldPosition); }
        export function cursorMove(e) { if (dragging) { shared.events += 'M'; thisLayer.origin = e.worldPosition.add(offset); } }
        export function cursorUp() { shared.events += 'U'; dragging = false; }
        export function cursorClick() { shared.events += 'C'; }
        export function update() { shared.trace = (++updates) + ':' + shared.events + ':' + input.cursorLeftDown; }
        """))
        let start = RuntimeVector2(x: 0.5, y: 0.5), end = RuntimeVector2(x: 0.9, y: 0.8)
        _ = runtime.step(deltaTime: 0, cursorPosition: start)
        let result = runtime.step(deltaTime: 0, cursorPosition: end, cursorEvents: [
            .init(position: start, leftDown: true), .init(position: end, leftDown: true), .init(position: end, leftDown: false)])
        #expect(result.nodes.first?.worldPosition == RuntimeVector3(x: 180, y: 80, z: 0))
        #expect(result.texts.first?.content == "2:DMUC:false")
    }

    @Test func multipleClicksAndCallbackFailureDoNotLoseLaterReleases() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        export function init() { shared.trace = ''; }
        export function cursorDown() { shared.trace += 'D'; throw Error('expected'); }
        export function cursorUp() { shared.trace += 'U'; }
        export function cursorClick() { shared.trace += 'C'; }
        """))
        let center = RuntimeVector2(x: 0.5, y: 0.5)
        _ = runtime.step(deltaTime: 0, cursorPosition: center)
        let result = runtime.step(deltaTime: 0, cursorPosition: center, cursorEvents: [true,false,true,false].map { .init(position: center, leftDown: $0) })
        #expect(result.texts.first?.content == "DUCDUC")
        #expect(runtime.step(deltaTime: 0, cursorPosition: center).texts.first?.content == "DUCDUC")
    }

    @Test func cancellationReleasesAuthoredDragWithoutClicking() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        let dragging = false;
        export function init() { shared.trace = ''; }
        export function cursorDown() { dragging = true; shared.trace += 'D'; }
        export function cursorMove() { if (dragging) shared.trace += 'M'; }
        export function cursorUp() { dragging = false; shared.trace += 'U'; }
        export function cursorClick() { shared.trace += 'C'; }
        """))
        let center = RuntimeVector2(x: 0.5, y: 0.5)
        _ = runtime.step(deltaTime: 0, cursorPosition: center)
        _ = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        let cancelled = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true, resetCursorEvents: true)
        #expect(cancelled.texts.first?.content == "DU")
        #expect(runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.6, y: 0.5)).texts.first?.content == "DUU")
        // Releasing inside without a captured press may still deliver cursorUp, but never click or move a stale drag.
    }

    @Test func pauseDeliversCleanupToAuthoredDrag() throws {
        let runtime = SceneRuntime(scene: try fixture(script: """
        let dragging = false;
        export function cursorDown() { dragging = true; }
        export function cursorUp() { dragging = false; shared.trace = 'released'; }
        export function cursorMove() { if (dragging) shared.trace = 'stale drag'; }
        """))
        let center = RuntimeVector2(x: 0.5, y: 0.5)
        _ = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        runtime.setPaused(true)
        _ = runtime.step(deltaTime: 0, cursorPosition: center, cursorLeftDown: true)
        runtime.setPaused(false)
        #expect(runtime.step(deltaTime: 0, cursorPosition: .init(x: 0.6, y: 0.5)).texts.first?.content == "released")
    }
}
