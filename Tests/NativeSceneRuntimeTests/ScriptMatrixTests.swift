import NativeSceneCore
@testable import NativeSceneRuntime
import Testing

struct ScriptMatrixTests {
    @Test func columnMajorTransformsDistinguishPointsDirectionsAndCompositionOrder() throws {
        try check("""
        const t = Mat4.compose(new Vec3(10,20,30), new Vec3(0,0,90), new Vec3(2,3,4));
        return t instanceof Mat4 && t.m.length === 16 && t.m[12] === 10 &&
            t.transformPoint(new Vec3(1,2,3)).distance(new Vec3(4,22,42)) < 1e-6 &&
            t.transformDirection(new Vec3(1,2,3)).distance(new Vec3(-6,2,12)) < 1e-6 &&
            t.multiply(new Vec4(1,2,3,1)).distance(new Vec4(4,22,42,1)) < 1e-6 &&
            t.translate(new Vec3(1,0,0)).translation().distance(new Vec3(10,22,30)) < 1e-6 &&
            t.translation().equals(new Vec3(10,20,30));
        """)
    }

    @Test func inversionNormalsAndIndependentCopiesPreserveGeometry() throws {
        try check("""
        const a = Mat4.compose(new Vec3(5,6,7), new Vec3(13,-24,35), new Vec3(2,3,4));
        const b = a.copy(); b.translation(new Vec2(8,9)); b.m[0] = 99;
        const n = a.normalMatrix(), tangent = a.transformDirection(new Vec3(1,0,0));
        return a.inverse().multiply(a).equals(Mat4.identity()) && Math.abs(a.determinant()-24) < 1e-6 &&
            a.transpose().transpose().equals(a) && a.add(a).equals(a.multiply(2)) &&
            a.add(b).subtract(b).equals(a) && a.m[0] !== 99 && b.translation().equals(new Vec3(8,9,0)) &&
            n instanceof Mat3 && Math.abs(n.multiply(new Vec3(0,1,0)).dot(tangent)) < 1e-6;
        """)
    }

    @Test func eulerDecompositionRoundTripsNonuniformAndMirroredTransforms() throws {
        try check("""
        for (const angles of [new Vec3(13,-24,35),new Vec3(0,90,20),new Vec3(0,-90,20)]) {
            for (const scale of [new Vec3(2,3,4),new Vec3(-2,3,4)]) {
                const a = Mat4.compose(new Vec3(1,2,3), angles, scale), d = a.decompose();
                if (!Mat4.compose(d.translation,d.rotation,d.scale).equals(a)) return false;
            }
        }
        return Mat4.fromRotation(90,new Vec3(0,0,5)).equals(Mat4.fromEuler(0,0,90)) &&
            Mat4.fromBasis(new Vec3(1,0,0),new Vec3(0,1,0),new Vec3(0,0,1)).equals(Mat4.identity());
        """)
    }

    @Test func viewMatrixPlacesEyeAtOriginAndTargetAlongNegativeZ() throws {
        try check("""
        const eye = new Vec3(3,4,5), center = new Vec3(3,4,1);
        const view = Mat4.lookAt(eye,center,new Vec3(0,1,0));
        return view.transformPoint(eye).length() < 1e-6 &&
            view.transformPoint(center).distance(new Vec3(0,0,-4)) < 1e-6 &&
            Mat4.identity().right().equals(new Vec3(1,0,0)) &&
            Mat4.identity().up().equals(new Vec3(0,1,0)) &&
            Mat4.identity().forward().equals(new Vec3(0,0,1));
        """)
    }

    @Test func mat3SupportsTwoDimensionalAffineAndVectorOperations() throws {
        try check("""
        const a = Mat3.compose(new Vec2(10,20),90,new Vec2(2,3));
        return a.m.length === 9 && a.m[6] === 10 && Math.abs(a.determinant()-6) < 1e-6 &&
            a.transformPoint(new Vec2(1,2)).distance(new Vec2(4,22)) < 1e-6 &&
            a.transformDirection(new Vec2(1,2)).distance(new Vec2(-6,2)) < 1e-6 &&
            a.multiply(new Vec3(1,2,1)).distance(new Vec3(4,22,1)) < 1e-6 &&
            Math.abs(a.angle()-90) < 1e-6 && a.inverse().multiply(a).equals(Mat3.identity()) &&
            a.transpose().transpose().equals(a) && a.add(a).subtract(a).equals(a) &&
            Mat3.fromMat4(Mat4.fromEuler(0,0,90)).equals(Mat3.fromRotation(90));
        """)
    }

    @Test func singularInverseIsExplicitAndZeroScaleDecomposesWithoutNaNs() throws {
        try check("""
        const m = Mat4.fromScale(new Vec3(0,2,3)), d=m.decompose();
        try { m.inverse(); return false; } catch (error) { if (!(error instanceof RangeError)) return false; }
        const m2=Mat3.compose(new Vec2(4,5),32,new Vec2(-2,3)), d2=m2.decompose();
        return d.rotation.length() === 0 && d.scale.equals(new Vec3(0,2,3)) &&
            Mat3.compose(d2.translation,d2.rotation,d2.scale).equals(m2);
        """)
    }

    @Test func matrixConstructorsAndRetainedValuesRemainAvailableAcrossCallbacks() throws {
        let host = ScriptHost()
        let source = """
        const saved = Mat4.fromTranslation(new Vec3(5,6,7));
        export function init(value) { shared.matrix = saved; return value; }
        export function update(value) {
            if (!(shared.matrix instanceof Mat4) || !saved.equals(shared.matrix)) return -1;
            shared.matrix = saved.translate(new Vec3(1,0,0));
            saved.translation(shared.matrix.translation());
            return saved.m[12];
        }
        """
        #expect(try host.evaluate(source: source, baseValue: .double(0), properties: [:]) == .double(6))
        #expect(try host.evaluate(source: source, baseValue: .double(6), properties: [:]) == .double(7))
    }

    private func check(_ body: String) throws {
        #expect(try ScriptHost().evaluate(source: "export function update() { \(body) }", baseValue: .bool(false), properties: [:]) == .bool(true))
    }
}
