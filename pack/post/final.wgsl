// the reference final pass: FidelityFX CAS, output encoding and 8-bit Bayer dithering.
// SDR input is display-encoded already; HDR input is linear, relative to paper white.

fn mu_cas_prep(c: vec3<f32>) -> vec3<f32> {
    // HDR is compressed to [0,1) with a reversible Reinhard before filtering (as in the HDR fork).
    if (hdr_enabled) { return mu_reinhard(mu_max0(c)); }
    return c;
}

fn mu_cas_tap(uv: vec2<f32>) -> vec3<f32> {
    return mu_cas_prep(textureSampleLevel(previous, nearest_sampler, uv, 0.0).rgb);
}

fn mu_min5(a: vec3<f32>, b: vec3<f32>, c: vec3<f32>, d: vec3<f32>, e: vec3<f32>) -> vec3<f32> {
    return min(a, min(b, min(c, min(d, e))));
}

fn mu_max5(a: vec3<f32>, b: vec3<f32>, c: vec3<f32>, d: vec3<f32>, e: vec3<f32>) -> vec3<f32> {
    return max(a, max(b, max(c, max(d, e))));
}

// Display-referred 3D LUT stored as a 33-slice horizontal atlas:
// width = 33*33, height = 33, slice b at x = b*33, inner x = red, y = green.
// Two slice samples plus the hardware's bilinear filtering give trilinear.
const MU_LUT_SIZE: f32 = 33.0;

fn mu_apply_lut(c: vec3<f32>) -> vec3<f32> {
    let n = MU_LUT_SIZE;
    let cc = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    // Pixel centres, not slice edges: red is a texel coordinate inside a
    // slice, so the last red texel must not blend with the next blue slice.
    let r = cc.r * (n - 1.0);
    let g = cc.g * (n - 1.0);
    let b = cc.b * (n - 1.0);
    let s = floor(b);
    let f = b - s;
    let u0 = (s * n + r + 0.5) / (n * n);
    let u1 = (min(s + 1.0, n - 1.0) * n + r + 0.5) / (n * n);
    let v = (g + 0.5) / n;
    let c0 = textureSampleLevel(lut, lut_sampler, vec2<f32>(u0, v), 0.0).rgb;
    let c1 = textureSampleLevel(lut, lut_sampler, vec2<f32>(u1, v), 0.0).rgb;
    return mix(c0, c1, f);
}

fn post(input: PostInput) -> vec4<f32> {
    let px = vec2<f32>(1.0) / frame.resolution;
    let uv = input.uv;
    var col = mu_cas_prep(input.color.rgb);

    if (cas_enabled) {
        // 3x3 neighbourhood:  a b c / d e f / g h i
        let a = mu_cas_tap(uv + vec2<f32>(-px.x, -px.y));
        let b = mu_cas_tap(uv + vec2<f32>(0.0, -px.y));
        let c = mu_cas_tap(uv + vec2<f32>(px.x, -px.y));
        let d = mu_cas_tap(uv + vec2<f32>(-px.x, 0.0));
        let e = col;
        let f = mu_cas_tap(uv + vec2<f32>(px.x, 0.0));
        let g = mu_cas_tap(uv + vec2<f32>(-px.x, px.y));
        let h = mu_cas_tap(uv + vec2<f32>(0.0, px.y));
        let i = mu_cas_tap(uv + vec2<f32>(px.x, px.y));

        let sharpness = cas_intensity * 2.0 - 1.0;

        var min_color = mu_min5(d, e, f, b, h);
        min_color = min_color + mu_min5(min_color, a, c, g, i);
        var max_color = mu_max5(d, e, f, b, h);
        max_color = max_color + mu_max5(max_color, a, c, g, i);

        var w = clamp(min(min_color, vec3<f32>(2.0) - max_color) / max(max_color, vec3<f32>(1e-4)), vec3<f32>(0.0), vec3<f32>(1.0));
        let inv = vec3<f32>(1.0) - w;
        w = vec3<f32>(1.0) - inv * inv;
        w = w * (-1.0 / mix(8.0, 5.0, sharpness));

        let weight_sum = vec3<f32>(1.0) + 4.0 * w;
        col = clamp((b + d + f + h) * w + e, vec3<f32>(0.0), vec3<f32>(1.0)) / weight_sum;
    }

    // Encode for the display.
    var out_c = col;
    if (hdr_enabled) {
        out_c = mu_reinhard_inverse(col);
        out_c = mu_srgb_encode(out_c);
    }

    // A photographic LUT is display-referred, so it goes after the encode.
    if (lut_enabled && lut_strength > 0.0) {
        let graded = mu_apply_lut(clamp(out_c, vec3<f32>(0.0), vec3<f32>(1.0)));
        out_c = mix(out_c, graded, lut_strength);
    }

    // 8-bit dithering with a 16x16 Bayer pattern, as in the reference.
    if (dither_enabled) {
        let pattern = mu_bayer16(floor(input.pixel));
        out_c = out_c + vec3<f32>(pattern / 255.0 - 0.5 / 255.0);
        if (!hdr_enabled) { out_c = clamp(out_c, vec3<f32>(0.0), vec3<f32>(1.0)); }
        else { out_c = max(out_c, vec3<f32>(0.0)); }
    }

    if (output_linear) { out_c = mu_srgb_decode(out_c); }
    return vec4<f32>(out_c, 1.0);
}
