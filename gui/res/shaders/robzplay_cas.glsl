// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play - AMD FidelityFX Contrast Adaptive Sharpening (CAS) for libplacebo.
// Recovers micro-contrast and crisp texture detail lost to Remote Play compression
// without ringing or haloing.
//
// @CAS_SHARPNESS@ is replaced when the shader is loaded (0.0 .. 1.0).

//!HOOK MAIN
//!BIND HOOKED
//!DESC Robz Play AMD FidelityFX CAS

#define CAS_SHARPNESS @CAS_SHARPNESS@

vec4 hook() {
    // Fetch a 3x3 cross + corners neighborhood
    vec3 a = HOOKED_texOff(vec2(-1.0, -1.0)).rgb;
    vec3 b = HOOKED_texOff(vec2( 0.0, -1.0)).rgb;
    vec3 c = HOOKED_texOff(vec2( 1.0, -1.0)).rgb;
    vec3 d = HOOKED_texOff(vec2(-1.0,  0.0)).rgb;
    vec3 e = HOOKED_texOff(vec2( 0.0,  0.0)).rgb;
    vec3 f = HOOKED_texOff(vec2( 1.0,  0.0)).rgb;
    vec3 g = HOOKED_texOff(vec2(-1.0,  1.0)).rgb;
    vec3 h = HOOKED_texOff(vec2( 0.0,  1.0)).rgb;
    vec3 i = HOOKED_texOff(vec2( 1.0,  1.0)).rgb;

    // Soft min and max (cross + 3x3 average for better stability on compressed video)
    vec3 mnRGB = min(min(min(d, e), min(f, b)), h);
    vec3 mnRGB2 = min(mnRGB, min(min(a, c), min(g, i)));
    mnRGB += mnRGB2;

    vec3 mxRGB = max(max(max(d, e), max(f, b)), h);
    vec3 mxRGB2 = max(mxRGB, max(max(a, c), max(g, i)));
    mxRGB += mxRGB2;

    // Smooth minimum distance to signal limit divided by smooth max
    vec3 rcpMRGB = 1.0 / max(mxRGB, vec3(1e-5));
    vec3 ampRGB = clamp(min(mnRGB, 2.0 - mxRGB) * rcpMRGB, 0.0, 1.0);
    ampRGB = inversesqrt(max(ampRGB, vec3(1e-5)));
    ampRGB = 1.0 / ampRGB;

    float peak = -1.0 / mix(8.0, 5.0, clamp(CAS_SHARPNESS, 0.0, 1.0));
    vec3 wRGB = ampRGB * peak;
    vec3 rcpWeightRGB = 1.0 / (1.0 + 4.0 * wRGB);

    vec3 window = (b + d) + (f + h);
    vec3 outColor = clamp((window * wRGB + e) * rcpWeightRGB, 0.0, 1.0);
    return vec4(outColor, HOOKED_tex(HOOKED_pos).a);
}
