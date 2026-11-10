// Screen-space reflections for water (and optionally wet ground).
// A hit replaces the reflection the material stage already painted (sky); a miss leaves it.
// Pixels are never changed unless a ray finds on-screen geometry.

fn post(input: PostInput) -> vec4<f32> {
    let src = input.color;
    if (ssr_mode == 0u || input.depth <= 0.0 || ssr_intensity <= 0.0) { return vec4<f32>(src.rgb, 1.0); }

    let uv = input.uv;
    let P = view_position(uv, input.depth);
    let dist = max(length(P), 0.01);

    // Failsafe: if projecting a reconstructed position does not land on its own pixel,
    // the matrices disagree with my assumptions, so skip SSR rather than draw garbage.
    let chk = mu_project(P);
    if (abs(chk.x - uv.x) > 0.01 || abs(chk.y - uv.y) > 0.01) { return vec4<f32>(src.rgb, 1.0); }

    let px = vec2<f32>(1.0) / frame.resolution;
    let dl = depth_at(uv - vec2<f32>(px.x, 0.0));
    let dr = depth_at(uv + vec2<f32>(px.x, 0.0));
    let du = depth_at(uv - vec2<f32>(0.0, px.y));
    let dd = depth_at(uv + vec2<f32>(0.0, px.y));
    if (dl <= 0.0 || dr <= 0.0 || du <= 0.0 || dd <= 0.0) { return vec4<f32>(src.rgb, 1.0); }

    let a = view_position(uv, input.depth);
    let pl = view_position(uv - vec2<f32>(px.x, 0.0), dl);
    let pr = view_position(uv + vec2<f32>(px.x, 0.0), dr);
    let pu = view_position(uv - vec2<f32>(0.0, px.y), du);
    let pd = view_position(uv + vec2<f32>(0.0, px.y), dd);
    let dx = select(pr - a, a - pl, dot(a - pl, a - pl) < dot(pr - a, pr - a));
    let dy = select(pd - a, a - pu, dot(a - pu, a - pu) < dot(pd - a, pd - a));
    let cr = cross(dx, dy);
    let cr2 = dot(cr, cr);
    if (cr2 < 1e-14) { return vec4<f32>(src.rgb, 1.0); }
    var n = cr * inverseSqrt(cr2);
    let V = P / dist;                 // from the camera to the surface
    if (dot(n, V) > 0.0) { n = -n; }

    // Only (nearly) horizontal, upward-facing surfaces reflect.
    if (n.y < 0.92) { return vec4<f32>(src.rgb, 1.0); }

    let lin = mu_scene_decode(src.rgb);

    // Water-like: blue dominates. Wet ground (mode 2) additionally follows rain.
    let water = smoothstep(0.0, 0.06, lin.b - max(lin.r, lin.g * 0.9));
    var mask = water;
    if (ssr_mode == 2u) { mask = max(mask, 0.6 * frame.rain); }
    if (mask <= 0.01) { return vec4<f32>(src.rgb, 1.0); }

    let ndv = mu_sat(dot(n, -V));
    let fresnel = 0.02 + 0.98 * pow(1.0 - ndv, 5.0);
    let weight = fresnel * mask * ssr_intensity;
    if (weight <= 0.005) { return vec4<f32>(src.rgb, 1.0); }

    let R = reflect(V, n);
    let jitter = mu_ign(input.pixel, frame.frame_index);

    var hit = false;
    var hit_uv = vec2<f32>(0.0);
    var t = 0.35 * (0.8 + 0.4 * jitter);
    let origin = P + n * 0.04;

    for (var i = 0; i < 28; i = i + 1) {
        let rp = origin + R * t;
        let pr2 = mu_project(rp);
        if (pr2.x < 0.0 || pr2.x > 1.0 || pr2.y < 0.0 || pr2.y > 1.0 || pr2.z < 0.0) { break; }
        let sd = depth_at(pr2.xy);
        if (sd > 0.0) {
            let q = view_position(pr2.xy, sd);
            let ray_d = length(rp);
            let surf_d = length(q);
            let diff = ray_d - surf_d;
            if (diff > 0.02 && diff < max(0.6, t * 0.35)) {
                hit = true;
                hit_uv = pr2.xy;
                break;
            }
        }
        t = t * 1.18;
    }

    if (!hit) { return vec4<f32>(src.rgb, 1.0); }

    // Fade towards screen edges to hide the cut-off.
    let e = min(min(hit_uv.x, 1.0 - hit_uv.x), min(hit_uv.y, 1.0 - hit_uv.y));
    let edge = smoothstep(0.0, 0.08, e);

    let refl = mu_scene_decode(textureSampleLevel(previous, linear_sampler, hit_uv, 0.0).rgb);
    let result = mix(lin, refl, mu_sat(weight * edge));
    return vec4<f32>(mu_scene_encode(result), 1.0);
}
