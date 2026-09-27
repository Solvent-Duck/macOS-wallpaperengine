varying vec3 v_Color;
#if GMODE == 1
vec3 tone(vec3 color) {
    return color;
}

void main() {
    v_Color = tone(v_Color);
    out_FragColor = vec4(v_Color, 1.0);
}
