// Overworld sky. This is the only sky: the manifest turns the engine's own
// clouds, sun and stars off, and the pack draws all of them here. The cloud
// layers are depth-aware post passes, not part of this dome, so they can be
// drawn below the camera as well as above; this stage supplies the atmosphere
// they blend into.
fn sky(input: SkyInput) -> vec4<f32> {
    let dir = normalize(input.direction);
    return vec4<f32>(mu_sky_encoded(dir, true), 1.0);
}
