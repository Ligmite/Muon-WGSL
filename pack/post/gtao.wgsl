// Ground-truth ambient occlusion from depth only (Jimenez et al. 2016).
// Writes the raw AO term into alpha; the next pass denoises and applies it.

fn mu_view_pos(uv: vec2<f32>) -> vec4<f32> {
    // xyz: camera-relative position, w: 1 if the texel holds geometry, 0 for sky.
    let d = depth_at(uv);
    if (d <= 0.0) { return vec4<f32>(0.0); }
    return vec4<f32>(view_position(uv, d), 1.0);
}

fn post(input: PostInput) -> vec4<f32> {
    let src = input.color;
    if (input.depth <= 0.0 || ao_strength <= 0.0) { return vec4<f32>(src.rgb, 1.0); }

    let uv = input.uv;
    let px = vec2<f32>(1.0) / frame.resolution;
    let P = view_position(uv, input.depth);
    let dist = max(length(P), 0.01);
    let V = -P / dist;

    // Normal from the smaller of the two one-sided depth differences on each axis.
    let pl = mu_view_pos(uv - vec2<f32>(px.x, 0.0));
    let pr = mu_view_pos(uv + vec2<f32>(px.x, 0.0));
    let pu = mu_view_pos(uv - vec2<f32>(0.0, px.y));
    let pd = mu_view_pos(uv + vec2<f32>(0.0, px.y));

    var dx = vec3<f32>(0.0);
    if (pl.w > 0.5 && pr.w > 0.5) {
        let a = P - pl.xyz;
        let b = pr.xyz - P;
        dx = select(b, a, dot(a, a) < dot(b, b));
    } else if (pl.w > 0.5) {
        dx = P - pl.xyz;
    } else if (pr.w > 0.5) {
        dx = pr.xyz - P;
    }
    var dy = vec3<f32>(0.0);
    if (pu.w > 0.5 && pd.w > 0.5) {
        let a = P - pu.xyz;
        let b = pd.xyz - P;
        dy = select(b, a, dot(a, a) < dot(b, b));
    } else if (pu.w > 0.5) {
        dy = P - pu.xyz;
    } else if (pd.w > 0.5) {
        dy = pd.xyz - P;
    }

    let cr = cross(dx, dy);
    let cr2 = dot(cr, cr);
    if (cr2 < 1e-14) { return vec4<f32>(src.rgb, 1.0); }
    var n = cr * inverseSqrt(cr2);
    if (dot(n, V) < 0.0) { n = -n; }

    // Search radius in pixels from the radius in blocks.
    let px_per_block = 0.5 * frame.resolution.y * abs(frame.projection[1][1]) / dist;
    let radius_px = clamp(ao_radius * px_per_block, 4.0, 160.0);

    let jit_a = mu_ign(input.pixel, frame.frame_index);
    let jit_b = mu_ign(input.pixel + vec2<f32>(17.0, 31.0), frame.frame_index);

    let slices = 4;
    let steps = 5;
    var vis_sum = 0.0;

    for (var s = 0; s < slices; s = s + 1) {
        let phi = (f32(s) + jit_a) * MU_PI / f32(slices);
        let dir = vec2<f32>(cos(phi), sin(phi));

        // The screen direction as a 3D direction at this pixel's depth.
        let p2 = view_position(uv + dir * px * 8.0, input.depth);
        let dv = normalize(p2 - P);
        let orth = dv - V * dot(dv, V);
        let axis = normalize(cross(dv, V));
        let proj_n = n - axis * dot(n, axis);
        let proj_len = length(proj_n) + 1e-5;
        let sign_n = select(-1.0, 1.0, dot(orth, proj_n) >= 0.0);
        let cos_n = clamp(dot(proj_n, V) / proj_len, 0.0, 1.0);
        let nang = sign_n * acos(cos_n);

        var c_neg = -1.0;
        var c_pos = -1.0;
        for (var side = 0; side < 2; side = side + 1) {
            let sgn = select(-1.0, 1.0, side == 1);
            var best = -1.0;
            for (var k = 0; k < steps; k = k + 1) {
                var t = (f32(k) + jit_b) / f32(steps);
                t = t * t;
                let off_px = max(t * radius_px, 1.5 + f32(k));
                let suv = uv + dir * (sgn * off_px) * px;
                let sd = depth_at(suv);
                if (sd > 0.0) {
                    let sp = view_position(suv, sd);
                    let delta = sp - P;
                    let dl = max(length(delta), 1e-4);
                    let h = dot(delta, V) / dl;
                    let w = clamp((dl - 0.6 * ao_radius) / (0.4 * ao_radius + 1e-4), 0.0, 1.0);
                    best = max(best, mix(h, -1.0, w));
                }
            }
            if (side == 0) { c_neg = best; } else { c_pos = best; }
        }

        var h1 = -acos(clamp(c_neg, -1.0, 1.0));
        var h2 = acos(clamp(c_pos, -1.0, 1.0));
        h1 = nang + max(h1 - nang, -0.5 * MU_PI);
        h2 = nang + min(h2 - nang, 0.5 * MU_PI);
        let a1 = -cos(2.0 * h1 - nang) + cos_n + 2.0 * h1 * sin(nang);
        let a2 = -cos(2.0 * h2 - nang) + cos_n + 2.0 * h2 * sin(nang);
        vis_sum = vis_sum + proj_len * 0.25 * (a1 + a2);
    }

    let ao = clamp(vis_sum / f32(slices), 0.0, 1.0);
    return vec4<f32>(src.rgb, ao);
}
