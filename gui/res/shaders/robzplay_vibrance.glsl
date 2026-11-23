// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play - Cinematic Vibrance, Local Clarity & Shadow/Highlight Polish.
// Enhances perceived dynamic range and color depth of compressed SDR/HDR streams
// without clipping highlights or oversaturating skin tones.
//
// @VIBRANCE@ and @CLARITY@ are replaced when the shader is loaded.

//!HOOK MAIN
//!BIND HOOKED
//!DESC Robz Play Cinematic Vibrance & Clarity

#define ROBZ_VIBRANCE @VIBRANCE@
#define ROBZ_CLARITY @CLARITY@

vec4 hook() {
    vec4 src = HOOKED_tex(HOOKED_pos);
    vec3 col = src.rgb;

    // 1. Subtle local micro-contrast (clarity) on midtones only
    if (ROBZ_CLARITY > 0.001) {
        vec3 n0 = HOOKED_texOff(vec2(-2.0, -2.0)).rgb;
        vec3 n1 = HOOKED_texOff(vec2( 2.0, -2.0)).rgb;
        vec3 n2 = HOOKED_texOff(vec2(-2.0,  2.0)).rgb;
        vec3 n3 = HOOKED_texOff(vec2( 2.0,  2.0)).rgb;
        vec3 blur = (n0 + n1 + n2 + n3) * 0.25;
        float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
        float midtone_mask = 4.0 * luma * (1.0 - luma); // peaks at 0.5, 0 at black/white
        col = clamp(col + (col - blur) * (ROBZ_CLARITY * midtone_mask), 0.0, 1.0);
    }

    // 2. Intelligent vibrance (boosts muted colors more than already saturated colors)
    if (ROBZ_VIBRANCE > 0.001) {
        float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
        float max_c = max(col.r, max(col.g, col.b));
        float min_c = min(col.r, min(col.g, col.b));
        float sat = max_c - min_c;
        float boost = ROBZ_VIBRANCE * (1.0 - sat);
        col = clamp(mix(vec3(luma), col, 1.0 + boost), 0.0, 1.0);
    }

    // 3. Gentle S-curve contrast lift for deeper blacks without crushing shadow detail
    vec3 s_curve = col * col * (3.0 - 2.0 * col);
    col = mix(col, s_curve, 0.08);

    return vec4(col, src.a);
}
