varying vec2 v_TexCoord;
uniform sampler2D g_Texture0; // {"default":"materials/test"}
uniform vec4 g_Tint; // Added for layer scale correction
// [COMBO] {"combo":"AA_CATEGORY","type":"options","default":0,"options":{Color:0,"UV":1}}
#require libs/noise

void main() {
    vec3 noise = vec3(sampleNoise(v_TexCoord), 0.0, 0.0);
    out_FragColor = texture(g_Texture0, v_TexCoord) + vec4(noise, 1.0) + g_Tint * 0.0;
}
