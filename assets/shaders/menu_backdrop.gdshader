shader_type canvas_item;
// Slow drifting corruption behind the title screen.
//
// Its own shader rather than a second instance of blight_overlay. The menu had been reusing the
// gameplay one, which reads its intensity from a per-tile texture the menu never assigns — so it
// depended entirely on whatever an unbound sampler happens to return, and any change to how
// corruption is drawn in the world silently changed or broke the title screen. Two very different
// jobs: one is terrain, this is atmosphere.
//
// Generates its own field, so it needs no texture and no game state — the menu runs before a world
// exists.

uniform vec3 deep : source_color = vec3(0.180, 0.039, 0.110);
uniform vec3 mid : source_color = vec3(0.345, 0.086, 0.227);
uniform vec3 glow : source_color = vec3(0.561, 0.141, 0.337);
uniform float drift = 0.02;
uniform float scale = 5.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Value noise. Smooth, unlike the gameplay shader's per-pixel hash — this is meant to look like
// something moving in the distance, not like soil under your feet.
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x),
		f.y);
}

void fragment() {
	float t = TIME * drift;
	// Two layers pulling in opposite directions, so the pattern never repeats visibly and never
	// reads as a scrolling texture.
	float a = noise(UV * scale + vec2(t, t * 0.6));
	float b = noise(UV * scale * 2.3 - vec2(t * 0.8, t * 1.3));
	float v = clamp(a * 0.65 + b * 0.35, 0.0, 1.0);

	vec3 col = mix(deep, mid, smoothstep(0.35, 0.75, v));
	// A faint bloom in the densest patches, so there is something for the eye to drift across
	// while the player decides what to press.
	col += glow * smoothstep(0.78, 1.0, v) * 0.5;

	// Vignette toward the edges keeps the centre of the screen readable behind the menu card.
	float edge = smoothstep(0.15, 0.75, distance(UV, vec2(0.5)));
	COLOR = vec4(col, (0.22 + 0.5 * smoothstep(0.5, 1.0, v)) * (0.35 + 0.65 * edge));
}
