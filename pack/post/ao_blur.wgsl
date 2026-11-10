// Depth-aware blur of the GTAO term (stored in alpha), then apply it in linear light.

fn mu_inv_depth(d: f32) -> f32 { return 1.0 / max(d, 1e-6); }

fn post(input: PostInput) -> vec4<f32> {
    let src = input.color;
    if (input.depth <= 0.0 || ao_strength <= 0.0) { return vec4<f32>(src.rgb, 1.0); }

    let px = vec2<f32>(1.0) / frame.resolution;
    let zc = mu_inv_depth(input.depth);

    var sum = src.a;
    var wsum = 1.0;
    // 12 taps on a sparse 5x5 pattern; fixed jitter-free layout.
    for (var i = 0; i < 12; i = i + 1) {
        var o = vec2<f32>(0.0);
        switch (i) {
            case 0: { o = vec2<f32>(-2.0, -1.0); }
            case 1: { o = vec2<f32>(-1.0, -2.0); }
            case 2: { o = vec2<f32>(1.0, -2.0); }
            case 3: { o = vec2<f32>(2.0, -1.0); }
            case 4: { o = vec2<f32>(-2.0, 1.0); }
            case 5: { o = vec2<f32>(-1.0, 2.0); }
            case 6: { o = vec2<f32>(1.0, 2.0); }
            case 7: { o = vec2<f32>(2.0, 1.0); }
            case 8: { o = vec2<f32>(-1.0, 0.0); }
            case 9: { o = vec2<f32>(1.0, 0.0); }
            case 10: { o = vec2<f32>(0.0, -1.0); }
            default: { o = vec2<f32>(0.0, 1.0); }
        }
        let suv = input.uv + o * px;
        let sd = depth_at(suv);
        if (sd > 0.0) {
            let zs = mu_inv_depth(sd);
            let w = exp(-abs(zs - zc) / (0.04 * zc + 0.02));
            let a = textureSampleLevel(previous, nearest_sampler, suv, 0.0).a;
            sum = sum + a * w;
            wsum = wsum + w;
        }
    }
    let ao = sum / wsum;

    // Apply in linear light; strength fades AO a little where light is bright.
    let lin = mu_scene_decode(src.rgb);
    let bright = smoothstep(0.6, 3.0, mu_luma709(lin));
    let k = ao_strength * (1.0 - 0.45 * bright);
    let applied = lin * mix(1.0, ao * ao, k);
    return vec4<f32>(mu_scene_encode(applied), 1.0);
}
