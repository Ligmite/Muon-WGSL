// Screen-space volumetric light (sun shafts), aerosol haze and underwater absorption.
// There is no shadow map to march through, so shafts come from sky occlusion in screen
// space (the reference's crepuscular-ray look), weighted by distance-based in-scatter.

fn mu_mie_phase(mu: f32) -> f32 {
    let g = 0.72;
    return (1.0 - g * g) / (4.0 * MU_PI * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
}

fn post(input: PostInput) -> vec4<f32> {
    let src = input.color;
    var lin = mu_scene_decode(src.rgb);

    let is_sky = input.depth <= 0.0;
    var dist = frame.far;
    var V = vec3<f32>(0.0, 1.0, 0.0);
    if (!is_sky) {
        let P = view_position(input.uv, input.depth);
        dist = max(length(P), 0.01);
        V = P / dist;
    } else {
        let P = view_position(input.uv, 0.5);
        V = normalize(P);
    }

    let sun = frame.sun_direction;
    let day = smoothstep(-0.06, 0.12, sun.y);
    let weather = 1.0 - 0.8 * frame.rain;

    // ------------------------------------------------------------------
    // Underwater: the reference's underwater absorption and scattering coefficients.
    // `[material] fog = false` means the terrain was not pre-fogged toward
    // vanilla blue, so the pack owns the whole water column here.
    // ------------------------------------------------------------------
    if (frame.eye_in == 1u) {
        lin = mu_scene_decode(src.rgb);

        let absorb = vec3<f32>(0.16, 0.065, 0.032) * underwater_density;
        let scatter_c = 0.035 * underwater_density;
        let d = min(dist, 80.0);
        let ext = absorb + vec3<f32>(scatter_c + 0.0005);
        let trans = exp(-ext * d);
        let sky_l = mu_sat(frame.eye_light.y);
        let light = (mu_sun_color(sun.y) * 0.9 + vec3<f32>(0.35, 0.45, 0.60)) * (0.25 + 0.75 * sky_l) * day
            + vec3<f32>(0.012, 0.022, 0.034);
        let inscatter = light * (vec3<f32>(scatter_c) / ext) * (vec3<f32>(1.0) - trans) * vec3<f32>(0.25, 0.65, 0.80);
        lin = lin * trans + inscatter;
        if (is_sky) { lin = inscatter + lin * 0.1; }
        return vec4<f32>(mu_scene_encode(lin), 1.0);
    }
    if (frame.eye_in != 0u) { return vec4<f32>(src.rgb, 1.0); }

    // ------------------------------------------------------------------
    // Distance fog: exponential height fog with the sky's own horizon
    // colour as its in-scatter. The optical depth is capped (in
    // `mu_aerial_fog`) so the far LOD is hazed, not erased.
    // ------------------------------------------------------------------
    let mu = dot(V, sun);
    if (!is_sky && fog_density > 0.0) {
        lin = mu_aerial_fog(frame.camera_position, V, dist, lin);
    }

    // ------------------------------------------------------------------
    // Sun shafts: march from this pixel towards the sun on screen and count sky.
    // ------------------------------------------------------------------
    if (vl_intensity > 0.0 && day > 0.0 && mu > 0.0) {
        let sp = mu_project(sun * 1000.0);
        if (sp.z > -5.0) {
            let sun_uv = sp.xy;
            let to_sun = sun_uv - input.uv;
            let len = length(to_sun);
            let march = to_sun * (min(len, 0.6) / max(len, 1e-4));
            let count = 18;
            let jitter = mu_ign(input.pixel, frame.frame_index);
            var occl = 0.0;
            var wsum = 0.0;
            for (var i = 0; i < count; i = i + 1) {
                let f = (f32(i) + jitter) / f32(count);
                let suv = input.uv + march * f;
                let inside = suv.x > 0.0 && suv.x < 1.0 && suv.y > 0.0 && suv.y < 1.0;
                let sd = depth_at(clamp(suv, vec2<f32>(0.001), vec2<f32>(0.999)));
                let w = 1.0 - f;
                let is_open = select(0.0, 1.0, sd <= 0.0 && inside);
                occl = occl + is_open * w;
                wsum = wsum + w;
            }
            let shafts = occl / max(wsum, 1e-4);

            // Distance in-scatter along the view ray; sky pixels get the full path.
            let path = select(1.0 - exp(-0.0016 * dist), 1.0, is_sky);
            let radial = mu_sat(1.0 - len * 0.9);
            let phase = mu_mie_phase(mu);
            let col = mu_sun_color(sun.y) * (phase * 0.9 * vl_intensity * day * weather);
            lin = lin + col * shafts * path * (0.4 + 0.6 * radial);
        }
    }

    return vec4<f32>(mu_scene_encode(lin), 1.0);
}
