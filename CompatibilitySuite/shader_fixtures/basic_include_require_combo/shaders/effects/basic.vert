attribute vec3 a_Position;
varying vec2 v_TexCoord;
#include "common/shared"

void main() {
    v_TexCoord = computeUV(a_Position.xy);
    gl_Position = vec4(a_Position, 1.0);
}
