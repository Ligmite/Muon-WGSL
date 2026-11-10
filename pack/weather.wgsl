// Rain and snow. The engine draws the streaks but does not light or fog them for
// a pack, and it still draws them inside water. Light them by the sky level and
// remove them entirely below the surface.
fn weather(input: WeatherInput) -> vec4<f32> {
    if (frame.eye_in != 0u) { return vec4<f32>(0.0); }

    let day = smoothstep(-0.08, 0.12, frame.sun_direction.y);
    let light = 0.20 + 0.80 * mu_sat(input.light.y);
    let tint = mix(vec3<f32>(0.32, 0.40, 0.62), vec3<f32>(1.0, 0.98, 0.95), day);
    let col = input.color.rgb * tint * light;

    let dist = length(input.position);
    let fade = 1.0 - smoothstep(frame.fog_start, max(frame.fog_end, frame.fog_start + 0.01), dist);
    return vec4<f32>(col, input.color.a * mix(1.0, fade, 0.35));
}
