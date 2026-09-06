// Soft cursor blink for Sora. Ghostty's built-in blink is binary on/off;
// this post-process paints a thicker teal bar and fades it with cosine
// ease-in-out between solid accent and transparent.
// Requires cursor-style-blink = false so the caret stays addressable.

const float BLINK_PERIOD = 1.8;
// Panda / Sora accent #19f9d8 — keep in sync with SoraTheme.pandaTeal.
const vec3 TEAL = vec3(0.098039, 0.976471, 0.847059);
// Extra pixels beyond Ghostty's bar so the caret reads clearly.
const float EXTRA_THICKNESS = 2.0;

float easeInOutOpacity(float time) {
    // Cosine ease: 1 → 0 → 1 over one period (smooth in and out).
    return 0.5 + 0.5 * cos(time * 6.28318530718 / BLINK_PERIOD);
}

bool inThickCursor(vec2 fragCoord, vec4 cursor) {
    // iCurrentCursor.xy is the -X / +Y corner; on Metal +Y is the bottom edge
    // and .w extends upward (decreasing y). Widen the bar for a thicker caret.
    float left = cursor.x - EXTRA_THICKNESS * 0.5;
    float right = cursor.x + cursor.z + EXTRA_THICKNESS * 0.5;
    float bottom = cursor.y;
    float top = cursor.y - cursor.w;
    return fragCoord.x >= left && fragCoord.x < right
        && fragCoord.y >= top && fragCoord.y < bottom;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 color = texture(iChannel0, uv);

    if (iCursorVisible == 0 || iFocus == 0 || iCurrentCursor.z <= 0.0) {
        fragColor = color;
        return;
    }

    if (!inThickCursor(fragCoord, iCurrentCursor)) {
        fragColor = color;
        return;
    }

    // Sample just outside the thickened bar so glass / cell background stays.
    float midX = iCurrentCursor.x + iCurrentCursor.z * 0.5;
    float half = iCurrentCursor.z * 0.5 + EXTRA_THICKNESS * 0.5;
    float outsideX = fragCoord.x < midX ? midX - half - 1.0 : midX + half + 1.0;
    outsideX = clamp(outsideX, 0.0, iResolution.x - 1.0);
    vec3 under = texture(iChannel0, vec2(outsideX, fragCoord.y) / iResolution.xy).rgb;

    // Prefer configured cursor color when it is already teal; otherwise force accent.
    vec3 accent = length(iCursorColor) > 0.01 ? iCursorColor : TEAL;
    float opacity = easeInOutOpacity(iTime);
    // Replace whatever Ghostty painted in the caret cells with teal ↔ transparent.
    color.rgb = mix(under, accent, opacity);
    fragColor = color;
}
