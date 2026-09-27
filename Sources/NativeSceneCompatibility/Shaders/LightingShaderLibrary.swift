/// Engine-side implementation for `#require LightingV1`. The material supplies
/// its PBR helpers; this library supplies scene lights and their attenuation.
enum LightingShaderLibrary {
    static let source = """
    #ifndef WE_LIGHTING_V1
    #define WE_LIGHTING_V1
    #if LIGHTING
    #if LIGHTS_POINT
    uniform vec4 g_LPoint_Origin[LIGHTS_POINT];
    uniform vec4 g_LPoint_Color[LIGHTS_POINT];
    uniform vec4 g_WELPoint_Falloff[LIGHTS_POINT];
    #endif
    #if LIGHTS_SPOT
    uniform vec4 g_LSpot_Origin[LIGHTS_SPOT];
    uniform vec4 g_LSpot_Direction[LIGHTS_SPOT];
    uniform vec4 g_LSpot_Color[LIGHTS_SPOT];
    uniform vec4 g_WELSpot_Falloff[LIGHTS_SPOT];
    #endif
    #if LIGHTS_TUBE
    uniform vec4 g_LTube_OriginA[LIGHTS_TUBE];
    uniform vec4 g_LTube_OriginB[LIGHTS_TUBE];
    uniform vec4 g_LTube_Color[LIGHTS_TUBE];
    uniform vec4 g_WELTube_Falloff[LIGHTS_TUBE];
    #endif
    #if LIGHTS_DIRECTIONAL
    uniform vec4 g_LDirectional_Direction[LIGHTS_DIRECTIONAL];
    uniform vec4 g_LDirectional_Color[LIGHTS_DIRECTIONAL];
    #endif

    vec3 WE_RadialLight(vec3 delta, vec4 lightColor, vec4 falloff,
        vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint,
        vec3 baseReflectance, float roughness, float metallic) {
        float distance = length(delta);
        if (lightColor.w <= 0.0 || distance >= falloff.x || distance <= 0.000001)
            return vec3(0.0);
        // common_pbr_2 already applies the radius/exponent falloff. The squared
        // intensity convention of older inverse-square helpers does not apply.
        return ComputePBRLightShadow(normal, delta, viewVector, color,
            lightColor.rgb * lightColor.w, falloff.x, falloff.y, specularTint,
            baseReflectance, roughness, metallic, 1.0);
    }

    vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal,
        vec3 viewVector, vec3 specularTint, vec3 baseReflectance,
        float roughness, float metallic) {
        vec3 light = vec3(0.0);
    #if LIGHTS_POINT
        for (int i = 0; i < LIGHTS_POINT; ++i) {
            light += WE_RadialLight(g_LPoint_Origin[i].xyz - worldPos,
                g_LPoint_Color[i], g_WELPoint_Falloff[i], color, normal,
                viewVector, specularTint, baseReflectance, roughness, metallic);
        }
    #endif
    #if LIGHTS_SPOT
        for (int i = 0; i < LIGHTS_SPOT; ++i) {
            vec3 delta = g_LSpot_Origin[i].xyz - worldPos;
            float spotCos = -dot(delta / max(length(delta), 0.000001), g_LSpot_Direction[i].xyz);
            float innerCos = g_LSpot_Origin[i].w;
            float outerCos = g_LSpot_Direction[i].w;
            float cone = innerCos > outerCos
                ? smoothstep(outerCos, innerCos, spotCos) : step(innerCos, spotCos);
            vec4 lightColor = g_LSpot_Color[i];
            lightColor.rgb *= cone;
            // Radius has its own uniform: origin.w stores the cone cosine.
            light += WE_RadialLight(delta, lightColor, g_WELSpot_Falloff[i],
                color, normal, viewVector, specularTint, baseReflectance, roughness, metallic);
        }
    #endif
    #if LIGHTS_TUBE
        for (int i = 0; i < LIGHTS_TUBE; ++i) {
            vec3 a = g_LTube_OriginA[i].xyz;
            vec3 segment = g_LTube_OriginB[i].xyz - a;
            float fraction = clamp(dot(worldPos - a, segment) / max(dot(segment, segment), 0.000001), 0.0, 1.0);
            vec3 delta = a + segment * fraction - worldPos;
            light += WE_RadialLight(delta, g_LTube_Color[i], g_WELTube_Falloff[i],
                color, normal, viewVector, specularTint, baseReflectance, roughness, metallic);
        }
    #endif
    #if LIGHTS_DIRECTIONAL
        for (int i = 0; i < LIGHTS_DIRECTIONAL; ++i) {
            vec4 lightColor = g_LDirectional_Color[i];
            if (lightColor.w > 0.0) {
                light += ComputePBRLightShadowInfinite(normal, g_LDirectional_Direction[i].xyz,
                    viewVector, color, lightColor.rgb * lightColor.w, specularTint,
                    baseReflectance, roughness, metallic, 1.0);
            }
        }
    #endif
        return light;
    }
    #endif
    #endif
    """
}
