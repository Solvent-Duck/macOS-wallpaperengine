import Foundation
import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ScriptVectorTests {
    @Test(arguments: [2, 3, 4])
    func constructorsAndArithmeticPreserveDimensions(size: Int) throws {
        let source = """
        export function update() {
            const C = globalThis['Vec\(size)'];
            const text = '1 2 3 4'.split(' ').slice(0, \(size)).join(' ');
            const original = new C(text);
            const copy = new C(original);
            copy.x = 10;
            if (original.x !== 1 || copy.x !== 10 || original.toString() !== text ||
                !new C().equals(new C(0)) || !new C(2).equals(new C().add(2)) ||
                !original.add(1).subtract(1).equals(original) ||
                !original.multiply(new C(2)).divide(2).equals(original)) throw new Error('constructor or arithmetic');
            return original;
        }
        """
        let expected: FrameValue = size == 2 ? .vec2([1, 2]) : (size == 3 ? .vec3([1, 2, 3]) : .vec4([1, 2, 3, 4]))
        #expect(try ScriptHost().evaluate(source: source, baseValue: expected, properties: [:]) == expected)
    }

    @Test func shorterVectorsAndComponentListsZeroFillRemainingDimensions() throws {
        let source = """
        export function update() {
            return new Vec3(1, 2).equals(new Vec3(1, 2, 0)) &&
                new Vec3(new Vec2(3, 4)).equals(new Vec3(3, 4, 0)) &&
                new Vec4(new Vec2(3, 4)).equals(new Vec4(3, 4, 0, 0)) &&
                new Vec4(1, 2, 3).equals(new Vec4(1, 2, 3, 0)) &&
                new Vec2(new Vec4(1, 2, 3, 4)).equals(new Vec2(1, 2));
        }
        """
        #expect(try ScriptHost().evaluate(source: source, baseValue: .bool(false), properties: [:]) == .bool(true))
    }

    @Test(arguments: [2, 3, 4])
    func geometryAndInterpolationReturnIndependentVectors(size: Int) throws {
        let source = """
        export function update() {
            const C = globalThis['Vec\(size)'];
            const a = new C(new Vec2(3, 4)), axis = new C(new Vec2(0, 1));
            return a.length() === 5 && a.lengthSqr() === 25 &&
                a.distance(new C()) === 5 && a.distanceSqr(new C()) === 25 &&
                a.normalize().equals(a.divide(5)) && a.project(axis).equals(new C(new Vec2(0, 4))) &&
                a.reflect(axis).equals(new C(new Vec2(3, -4))) &&
                a.mix(new C(), 0.5).equals(a.multiply(0.5)) &&
                a.negate().add(a).equals(new C()) && a.isFinite() &&
                !new C(Infinity).isFinite() && !new C(NaN).isFinite() && a.x === 3;
        }
        """
        #expect(try ScriptHost().evaluate(source: source, baseValue: .bool(false), properties: [:]) == .bool(true))
    }

    @Test(arguments: [2, 3, 4])
    func componentFunctionsHandleNegativeInputsAndScalarBounds(size: Int) throws {
        let source = """
        export function update() {
            const C = globalThis['Vec\(size)'];
            const a = new C(-1.75), b = new C(0.5);
            return a.fract().equals(new C(0.25)) && a.mod(1).equals(new C(0.25)) &&
                a.abs().equals(new C(1.75)) && a.sign().equals(new C(-1)) &&
                a.round().equals(new C(-2)) && a.floor().equals(new C(-2)) && a.ceil().equals(new C(-1)) &&
                a.min(b).equals(a) && a.max(b).equals(b) && a.clamp(-1, new C(1)).equals(new C(-1)) &&
                b.step(0.5).equals(new C(1)) && b.step(0.6).equals(new C(0)) &&
                b.smoothStep(0, 1).equals(b) && new C(-1).smoothStep(0, 1).equals(new C()) &&
                new C(2).smoothStep(0, 1).equals(new C(1));
        }
        """
        #expect(try ScriptHost().evaluate(source: source, baseValue: .bool(false), properties: [:]) == .bool(true))
    }

    @Test func vec4ValuesStayTypedThroughInitializationAndSuccessiveFrames() throws {
        let host = ScriptHost()
        let source = """
        const props = createScriptProperties().addColor({name:'tint',value:new Vec4(1)}).finish();
        export function init(value) { return 2; }
        export function update(value) {
            if (!(value instanceof Vec4) || !(props.tint instanceof Vec4)) throw new Error('lost Vec4 prototype');
            return value.add(props.tint).mix(new Vec4(10), new Vec4(0, 0.5, 1, 0));
        }
        """
        func value(_ frame: UInt64) throws -> FrameValue {
            try host.evaluate(source: source, baseValue: .vec4([0, 0, 0, 0]),
                properties: ["tint": .vec4([1, 2, 3, 4])],
                engine: SceneScriptEngineState(runtime: Double(frame), screenResolution: .zero, frameIndex: frame))
        }
        #expect(try value(0) == .vec4([3, 7, 10, 6]))
        #expect(try value(1) == .vec4([4, 9.5, 10, 10]))
    }

    @Test func callbackObjectsPreserveFourthComponents() throws {
        let host = ScriptHost()
        let source = "export function init() { thisObject.tint = thisObject.tint.add(new Vec4(1)); } export function applyUserProperties() { thisObject.tint = thisObject.tint.multiply(new Vec4(2)); }"
        let engine = SceneScriptEngineState(runtime: 0, screenResolution: .zero)
        let initial = try host.executeSceneCallback(source: source, callback: .initialize,
            thisObject: ["tint": .vec4([1, 2, 3, 4])], changedUserProperties: [:], engine: engine,
            input: SceneScriptInputState(cursorPosition: nil))
        #expect(initial["tint"] == .vec4([2, 3, 4, 5]))
        let changed = try host.executeSceneCallback(source: source, callback: .applyUserProperties,
            thisObject: initial, changedUserProperties: [:], engine: engine,
            input: SceneScriptInputState(cursorPosition: nil))
        #expect(changed["tint"] == .vec4([4, 6, 8, 10]))
    }

    @Test func specialGeometryUsesDegreesAndHandlesTotalInternalReflection() throws {
        let source = """
        export function update() {
            const a = new Vec3(1, 0, 0), b = new Vec3(0, 1, 0);
            const spherical = Vec3.fromSpherical(2, 90, 90);
            return a.cross(b).equals(new Vec3(0, 0, 1)) && a.angleBetween(b) === 90 &&
                new Vec2(3, 4).perpendicular().dot(new Vec2(3, 4)) === 0 &&
                spherical.equals(new Vec3(0, 0, 2)) && spherical.toSpherical().equals(new Vec3(2, 90, 90)) &&
                new Vec3(0, -1, 0).refract(b, 0.5).equals(new Vec3(0, -1, 0)) &&
                a.refract(b, 2).equals(new Vec3());
        }
        """
        #expect(try ScriptHost().evaluate(source: source, baseValue: .bool(false), properties: [:]) == .bool(true))
    }
}
