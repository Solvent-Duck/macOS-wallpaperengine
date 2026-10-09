@testable import NativeSceneCompatibility
import Testing

struct ShaderHLSLRepairTests {
    @Test func runtimeGlobalConstBecomesMacro() {
        #expect(ShaderGlobalConstantRepair.macro(for: "const float FEATHER = u_Feather * 0.5;")
            == "#define FEATHER (u_Feather * 0.5)")
        #expect(ShaderGlobalConstantRepair.macro(for: "const vec2 ratio = vec2(g_Texture0Resolution.x / g_Texture0Resolution.y, 1.0); // aspect")
            == "#define ratio (vec2(g_Texture0Resolution.x / g_Texture0Resolution.y, 1.0))")
    }

    @Test func declarationsAMacroCannotExpressAreLeftAlone() {
        #expect(ShaderGlobalConstantRepair.macro(for: "const float a = 1.0, b = u_x;") == nil)
        #expect(ShaderGlobalConstantRepair.macro(for: "const float weights[3] = float[3](1.0, 2.0, 3.0);") == nil)
        #expect(ShaderGlobalConstantRepair.macro(for: "float notConst = u_x;") == nil)
    }

    @Test func preprocessorTestsOnRuntimeValuesAreFalse() {
        let body = """
        #if g_Texture0Resolution.x < g_Texture0Resolution.y
        #define ratioDiff (vec2(1.0, g_ratio))
        #elif TYPE == 1
        #define ratioDiff (vec2(g_ratio, 1.0))
        #endif
        """
        let rewritten = ShaderPipeline.neutralizeRuntimeConditions(in: body).components(separatedBy: "\n")
        #expect(rewritten[0].hasPrefix("#if 0 "))
        #expect(rewritten[2] == "#elif TYPE == 1")
    }

    @Test func ordinaryConditionsAndFloatLiteralsAreUntouched() {
        let body = "#if SHADERVERSION >= 62\n#if VERSION > 1.5\n"
        #expect(ShaderPipeline.neutralizeRuntimeConditions(in: body) == body)
    }
}
