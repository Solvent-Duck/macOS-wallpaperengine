attribute vec3 a_Position;
varying vec3 v_Color;

void main() {
    v_Color = a_Position * 0.5 + vec3(0.5);
    gl_Position = vec4(a_Position, 1.0);
}
