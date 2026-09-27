import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ScriptColorTests {
    @Test func namespaceImportReturnsChainableVec3ValuesWithoutMutatingInputs() throws {
        let source = """
        import * as WEColor from 'WEColor';
        export function update() {
            const rgb = new Vec3(1, 0, 0);
            const hsv = WEColor.rgb2hsv(rgb);
            const restored = WEColor.hsv2rgb(hsv);
            if (!(hsv instanceof Vec3) || !(restored instanceof Vec3) || !rgb.equals(new Vec3(1, 0, 0))) throw new Error('Vec3 contract');
            return restored.add(new Vec3(0, 1, 0));
        }
        """
        #expect(try ScriptHost().evaluate(source: source, baseValue: .vec3([0, 0, 0]), properties: [:]) == .vec3([1, 1, 0]))
    }

    @Test func namedImportsHandleGrayscaleHueWrappingAndColorRangeComposition() throws {
        let source = """
        import { rgb2hsv, hsv2rgb, normalizeColor, expandColor } from 'WEColor';
        export function update() {
            const gray = rgb2hsv({x:0.5, y:0.5, z:0.5});
            const wrapped = hsv2rgb({x:-0.25, y:1, z:1});
            const source = {x:255, y:128, z:0};
            const restored = expandColor(normalizeColor(source));
            const close = (a, b) => Math.abs(a - b) < 0.0001;
            return gray instanceof Vec3 && gray.equals(new Vec3(0, 0, 0.5)) &&
                wrapped instanceof Vec3 && close(wrapped.x, 0.5) && close(wrapped.y, 0) && close(wrapped.z, 1) &&
                restored instanceof Vec3 && close(restored.x, 255) && close(restored.y, 128) && close(restored.z, 0) &&
                source.x === 255 && source.y === 128 && source.z === 0;
        }
        """
        #expect(try ScriptHost().evaluate(source: source, baseValue: .bool(false), properties: [:]) == .bool(true))
    }

    @Test func scalarCompatibilityAliasesStillReturnPlainColorObjects() throws {
        let source = """
        import * as WEColor from 'WEColor';
        export function update() {
            const hsv = WEColor.rgbToHsv(1, 0, 0);
            const rgb = WEColor.hsvToRgb(0, 1, 1);
            const negativeHue = WEColor.hsvToRgb(-0.25, 1, 1);
            return !(hsv instanceof Vec3) && !(rgb instanceof Vec3) &&
                hsv.x === 0 && hsv.y === 1 && hsv.z === 1 &&
                rgb.x === 1 && rgb.y === 0 && rgb.z === 0 &&
                negativeHue.x === 1 && negativeHue.y === 0 && negativeHue.z === 0.5;
        }
        """
        #expect(try ScriptHost().evaluate(source: source, baseValue: .bool(false), properties: [:]) == .bool(true))
    }
}
