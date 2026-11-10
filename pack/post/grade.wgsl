// Bloom + exposure + vignette + the reference colour grading + tonemapping (c19_color_grading).
// Output: SDR -> display-referred encoded [0,1]; HDR -> linear Rec.709, 1.0 = paper white.

fn mu_bloom_tap(uv: vec2<f32>) -> vec3<f32> {
    let c = mu_scene_decode(textureSampleLevel(previous, linear_sampler, uv, 0.0).rgb);
    // Only HDR highlights (sun disc, emissive blocks) should bloom. Without
    // this, a bright cloud drifting past produces its own moving glow.
    let l = mu_luma709(c);
    let w = smoothstep(bloom_threshold, bloom_threshold * 1.8, l);
    return c * w;
}

fn mu_bloom(uv: vec2<f32>) -> vec3<f32> {
    let px = vec2<f32>(1.0) / frame.resolution;
    let scale = (frame.resolution.y / 1080.0) * bloom_spread;
    var acc = vec3<f32>(0.0);
    var wsum = 0.0;
    // Three rings approximate the reference's wide mip-chain bloom (small, medium, large).
    for (var ring = 0; ring < 3; ring = ring + 1) {
        var radius = 6.0;
        var taps = 12;
        var weight = 0.50;
        if (ring == 1) { radius = 22.0; weight = 0.32; }
        if (ring == 2) { radius = 70.0; taps = 8; weight = 0.18; }
        let r = radius * scale;
        for (var i = 0; i < taps; i = i + 1) {
            let a = (f32(i) + 0.5 * f32(ring)) * (2.0 * MU_PI / f32(taps));
            let o = vec2<f32>(cos(a), sin(a)) * r * px;
            acc = acc + mu_bloom_tap(uv + o) * weight;
            wsum = wsum + weight;
        }
    }
    return acc / wsum;
}

// Auto exposure from the eased camera light, not a per-frame screen average.
// A screen average follows whatever is under the crosshair, so walking past a
// bright or dark surface makes the whole image pump.
fn mu_auto_exposure() -> f32 {
    if (auto_exposure == 0u) { return 1.0; }
    let sky = frame.eye_light_smooth.y;
    let lum = 0.06 + 0.24 * sky;
    let ev = log2(0.30 / max(lum, 1e-3)) + ae_bias;
    return exp2(clamp(ev, ae_min, ae_max));
}

// Screen-space lens flare anchored to the sun's projected position. Ghosts are
// samples of the scene reflected through the frame centre, as a real lens does.
fn mu_lens_flare(uv: vec2<f32>) -> vec3<f32> {
    if (!lens_flare || lens_flare_intensity <= 0.0) { return vec3<f32>(0.0); }
    let sp = mu_project(frame.sun_direction * 1000.0);
    if (sp.z <= 0.0) { return vec3<f32>(0.0); }
    let sun_uv = sp.xy;
    let aspect = frame.resolution.x / max(frame.resolution.y, 1.0);
    // Require the sun to be reasonably centred, not merely one texel on screen.
    let centered = 1.0 - smoothstep(0.28, 0.62, length((sun_uv - vec2<f32>(0.5)) * vec2<f32>(aspect, 1.0)));
    let edge = smoothstep(0.0, 0.12, min(min(sun_uv.x, 1.0 - sun_uv.x), min(sun_uv.y, 1.0 - sun_uv.y)));
    let visible = centered * edge;
    if (visible <= 0.0) { return vec3<f32>(0.0); }

    let d = (uv - sun_uv) * vec2<f32>(aspect, 1.0);
    let r = length(d);
    let halo = exp(-r * 5.0) * 0.050 + exp(-r * 24.0) * 0.200;
    let streak = exp(-abs(d.y) * 70.0) * exp(-abs(d.x) * 1.5) * 0.100;
    var col = vec3<f32>(0.95, 0.75, 0.45) * halo + vec3<f32>(0.45, 0.62, 1.0) * streak;

    let center = vec2<f32>(0.5);
    for (var i = 1; i <= 4; i = i + 1) {
        let k = 1.15 + 0.28 * f32(i);
        let g = sun_uv + (center - sun_uv) * k;
        if (g.x > 0.0 && g.x < 1.0 && g.y > 0.0 && g.y < 1.0) {
            let gcol = mu_scene_decode(textureSampleLevel(previous, linear_sampler, g, 0.0).rgb);
            let tint = select(vec3<f32>(0.70, 0.85, 1.0), vec3<f32>(1.0, 0.65, 0.35), (i % 2) == 0);
            col = col + gcol * tint * (0.025 / f32(i));
        }
    }
    return col * lens_flare_intensity * visible;
}

fn post(input: PostInput) -> vec4<f32> {
    var scene = mu_scene_decode(input.color.rgb);

    // Bloom: the reference mixes 12% of the blurred scene in at intensity 1.
    if (bloom_intensity > 0.0) {
        let bloom = mu_bloom(input.uv);
        scene = mix(scene, bloom, 0.12 * bloom_intensity);
    }

    scene = scene + mu_lens_flare(input.uv);

    // Exposure (the reference default EV 0), vignette.
    scene = scene * (exp2(exposure_ev) * mu_auto_exposure());
    scene = scene * mu_vignette(input.uv);

    // Working space is Rec.2020 as in the reference.
    var rgb = scene * MU_709_TO_2020;
    rgb = mu_grade_input(rgb);

    if (hdr_enabled) {
        // HDR fork: tonemap in Rec.2020 to paper-white-relative values, grade in a
        // reversible Reinhard-compressed domain, then expand again.
        rgb = mu_tonemap_hdr(rgb);
        rgb = rgb * MU_2020_TO_709;
        rgb = mu_max0(rgb);
        let compressed = mu_reinhard(rgb);
        let graded = mu_grade_output(compressed);
        rgb = mu_reinhard_inverse(graded);
        return vec4<f32>(rgb, 1.0);
    }

    rgb = mu_tonemap_sdr(rgb);
    rgb = mu_sat3(rgb * MU_2020_TO_709);
    rgb = mu_grade_output(rgb);
    rgb = mu_srgb_encode(mu_sat3(rgb));
    return vec4<f32>(mu_sat3(rgb), 1.0);
}
