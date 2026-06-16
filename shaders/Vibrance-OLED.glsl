//!PARAM vibrance_strength
//!DESC Global Vibrance Strength
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.3

//!PARAM skin_strength
//!DESC Skintone Protection Strength
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.5

//!PARAM midtone_strength
//!DESC Midtone Boost Strength
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.6

//!PARAM luma_strength
//!DESC Luma Protection Strength
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.4

//!HOOK MAIN
//!BIND HOOKED
//!DESC OLED Vibrance + Cinema

// Precomputed Constants For (k=6.0)
#define SIG_LOW    0.04742587
#define SIG_INV_DIFF   1.10478112
#define LUMA_COEFF     vec3(0.212656, 0.715158, 0.072186)

// Precomputed unit vector for skintone hue angle (123°) in CbCr space (cos(123°), sin(123°))
#define SKIN_DIR   vec2(-0.544639, 0.838671)

// Normalized Sigmoid Function (k=6.0)
float sigmoid_curve(float x) {
    float sig = 1.0 / (1.0 + exp(-6.0 * (x - 0.5)));
    return clamp((sig - SIG_LOW) * SIG_INV_DIFF, 0.0, 1.0);
}

// Convert RGB to CbCr (Rec. 709)
vec2 rgb_to_cbcr(vec3 color) {
    float y = dot(color, LUMA_COEFF);
    float cb = (color.b - y) * 0.5389;
    float cr = (color.r - y) * 0.6350;

    return vec2(cb, cr);
}

float skin_detector(vec3 color) {
  vec2 cbcr = rgb_to_cbcr(color);
  float saturation = length(cbcr);

  if (saturation < 0.001) {
    return 0.0;
  }

  vec2 cbcr_dir = cbcr / saturation;
  
  // Dot product measures alignment with skin angle (1.0 = exact match)
  float hue_alignment = dot(cbcr_dir, SKIN_DIR);
  
  // Convert angle thresholds (30° cone + 5° falloff) to cosine space (cos(30°) ≈ 0.866, cos(35°) ≈ 0.819)
  float hue_filter = smoothstep(0.819, 0.866, hue_alignment); 
  float saturation_filter = smoothstep(0.03, 0.06, saturation) * (1.0 - smoothstep(0.25, 0.35, saturation));

  float skin_filter = hue_filter * saturation_filter;

  return clamp(skin_filter, 0.0, 1.0);
}

float midtone_detector(float luma) {
    float shadow_filter = smoothstep(0.1, 0.3, luma);
    float highlight_filter = 1.0 - smoothstep(0.7, 0.9, luma);

    float midtone_filter = shadow_filter * highlight_filter;

    return clamp(midtone_filter, 0.0, 1.0);
}

float luma_detector(float luma) {
    float shadow_filter = 1.0 - smoothstep(0.0,  0.1, luma);
    float highlight_filter = smoothstep(0.85, 1.0, luma);

    float luma_filter = shadow_filter + highlight_filter;

    return clamp(luma_filter, 0.0, 1.0);
}

float combined_filter(vec3 color, float luma) {
    float skin_protection = mix(1.0, 1.0 - skin_detector(color), skin_strength);
    float luma_protection = mix(1.0, 1.0 - luma_detector(luma), luma_strength);
    float midtone_boost = 1.0 + midtone_detector(luma) * midtone_strength;

    float mask = skin_protection * luma_protection * midtone_boost;
    return mask;
}

// Core Vibrance Effect
vec3 apply_vibrance(vec3 color) {
    float luma = dot(color, LUMA_COEFF);
    vec3 chroma = color - vec3(luma);
    float saturation = length(chroma);

    float curve = sigmoid_curve(1.0 - saturation);
    float vibrance_filter = combined_filter(color, luma);

    float factor = 1.0 + curve * vibrance_filter * vibrance_strength;
    vec3 boosted_chroma = chroma * factor;

    return vec3(luma) + boosted_chroma;
}

vec4 hook() {
    vec4 rgb_color = HOOKED_tex(HOOKED_pos);
    vec3 color = rgb_color.rgb;

    color = apply_vibrance(color);

    return vec4(color, rgb_color.a);
}