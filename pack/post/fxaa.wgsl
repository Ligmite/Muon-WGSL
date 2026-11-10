// Edge-aware FXAA (compact variant).
// SDR input is already display-encoded; HDR input is linear and relative to paper white.

fn mu_fx_prep(c: vec3<f32>) -> vec3<f32> {
    if (hdr_enabled) { return mu_reinhard(mu_max0(c)); }
    return c;
}

fn mu_fx_tap(uv: vec2<f32>) -> vec3<f32> {
    return mu_fx_prep(textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb);
}

fn mu_fx_luma(c: vec3<f32>) -> f32 { return dot(c, vec3<f32>(0.299, 0.587, 0.114)); }

fn post(input: PostInput) -> vec4<f32> {
    let px = vec2<f32>(1.0) / frame.resolution;
    let uv = input.uv;
    let m = mu_fx_prep(input.color.rgb);
    var result = m;

    if (fxaa_enabled) {
        let n = mu_fx_tap(uv + vec2<f32>(0.0, -px.y));
        let s = mu_fx_tap(uv + vec2<f32>(0.0, px.y));
        let e = mu_fx_tap(uv + vec2<f32>(px.x, 0.0));
        let w = mu_fx_tap(uv + vec2<f32>(-px.x, 0.0));

        let lm = mu_fx_luma(m);
        let ln = mu_fx_luma(n);
        let ls = mu_fx_luma(s);
        let le = mu_fx_luma(e);
        let lw = mu_fx_luma(w);

        let l_min = min(lm, min(min(ln, ls), min(lw, le)));
        let l_max = max(lm, max(max(ln, ls), max(lw, le)));
        let luma_range = l_max - l_min;

        if (luma_range >= max(0.0312, l_max * 0.125)) {
            let lnw = mu_fx_luma(mu_fx_tap(uv + vec2<f32>(-px.x, -px.y)));
            let lne = mu_fx_luma(mu_fx_tap(uv + vec2<f32>(px.x, -px.y)));
            let lsw = mu_fx_luma(mu_fx_tap(uv + vec2<f32>(-px.x, px.y)));
            let lse = mu_fx_luma(mu_fx_tap(uv + vec2<f32>(px.x, px.y)));

            let edge_h = abs(-2.0 * lw + (lnw + lsw)) + abs(-2.0 * lm + (ln + ls)) * 2.0 + abs(-2.0 * le + (lne + lse));
            let edge_v = abs(-2.0 * ln + (lnw + lne)) + abs(-2.0 * lm + (lw + le)) * 2.0 + abs(-2.0 * ls + (lsw + lse));
            let is_h = edge_h >= edge_v;

            // Neighbours across the edge: vertical for a horizontal edge, horizontal otherwise.
            let l1 = select(lw, ln, is_h);
            let l2 = select(le, ls, is_h);
            let towards_neg = abs(l1 - lm) >= abs(l2 - lm);
            let dir_sign = select(1.0, -1.0, towards_neg);
            let perp = select(vec2<f32>(px.x, 0.0), vec2<f32>(0.0, px.y), is_h) * dir_sign;

            // A bilinear tap half a pixel across the edge is an even mix of both sides.
            let across = mu_fx_tap(uv + perp * 0.5);

            let l_avg = (ln + ls + le + lw) * 0.25;
            var subpix = mu_sat(abs(l_avg - lm) / max(luma_range, 1e-4));
            subpix = smoothstep(0.0, 1.0, subpix);
            subpix = subpix * subpix * 0.75;
            let avg4 = (n + s + e + w + m) * 0.2;

            result = mix(m, across, 0.75);
            result = mix(result, avg4, subpix);
        }
    }

    // Output stays unencoded here; the CAS pass encodes and dithers.
    var out_c = result;
    if (hdr_enabled) { out_c = mu_reinhard_inverse(result); }
    return vec4<f32>(out_c, 1.0);
}
