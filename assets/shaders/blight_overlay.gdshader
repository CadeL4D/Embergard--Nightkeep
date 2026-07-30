shader_type canvas_item;
// Corrupted GROUND, drawn in one pass from a single W*H FORMAT_R8 texture where red is
// corruption intensity.
//
// Still a shader rather than a TileMapLayer for the original reason: painting blight into tiles
// means thousands of set_cell calls per spread pass, which hitches badly on mobile. The CPU
// writes a ~16 KB texture every couple of seconds and the GPU does the rest.
//
// But this version is deliberately NOT an overlay. The first one warped its lookup off the tile
// grid, faded out with smooth translucent alpha, and pulsed on a sine — three things that read as
// coloured fog hovering above the world. Corruption is supposed to BE the terrain: the soil itself
// has turned. So:
//
//   * no UV warp, so edges land on tile boundaries like every other tile in the game
//   * fully OPAQUE where the ground has been taken — clean grass does not show through
//   * the frontier fades by ORDERED DITHER, dropping whole pixels, which is how pixel art fades
//   * per-pixel speckle at the game's 16px tile resolution, so corrupted ground carries the same
//     grain as the baked terrain tiles rather than being a flat wash
//   * no animation on the body of it. Ground does not breathe.
//
// The palette is lifted from ArtData's blight ramp ("b", "B", "P"), so corrupted soil and the
// corrupted creatures standing on it are drawn from the same three colours.

uniform sampler2D blight_tex : filter_nearest;
uniform vec2 grid_size = vec2(128.0, 128.0);
// Pixels per tile. Speckle is generated at this resolution so it matches the tileset's grain.
uniform float tile_px = 16.0;

uniform vec3 soil_deep : source_color = vec3(0.180, 0.039, 0.110);
uniform vec3 soil_mid : source_color = vec3(0.345, 0.086, 0.227);
uniform vec3 flesh : source_color = vec3(0.561, 0.141, 0.337);

// Intensity at which the ground counts as fully consumed and every pixel of the tile is soil.
//
// Sized against the actual data, not picked by eye. BlightField seeds a newly taken tile at 90 of
// 255 (~0.35) and ramps it by 6 per pass up to 255 (1.0), so this value is what decides how a
// tile LOOKS over its lifetime:
//
//   0.87  fresh tile shows ~40% of its pixels, deepening to solid as it is held
//
// Set it at or below 0.35 and every tile is opaque the instant it turns, which throws away the
// stippled frontier entirely and makes the Blight advance in hard rectangles.
uniform float take_hold = 0.87;

// Intensity at which the baked corrupted TILE takes over and this shader stops drawing. Must
// match TileAtlas.CORRUPT_THRESHOLD / 255 — 150/255 — or the two will either double up or leave
// a visible gap in the transition.
uniform float tile_takeover = 0.588;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// 4x4 ordered dither, computed arithmetically rather than from a lookup table — GDShader's array
// initialiser syntax varies between versions and this needs none.
float bayer4(vec2 p) {
	vec2 i = floor(mod(p, 4.0));
	float b = mod(i.x, 2.0) * 8.0
		+ mod(i.y, 2.0) * 4.0
		+ mod(floor(i.x * 0.5), 2.0) * 2.0
		+ mod(floor(i.y * 0.5), 2.0);
	return b / 16.0;
}

void fragment() {
	// One intensity per TILE. The texture is one texel per tile and sampled nearest, so this is
	// already quantised — the old version's warp is what smeared it across boundaries.
	float intensity = texture(blight_tex, UV).r;
	if (intensity <= 0.003) {
		discard;
	}

	// World pixel coordinate, so speckle is stable in the world rather than swimming with the
	// camera, and always lands on whole game pixels.
	vec2 px = floor(UV * grid_size * tile_px);

	// Above the takeover line the TILE is corrupted terrain, baked from CORRUPT_GROUND — so this
	// steps aside entirely. The shader's only remaining job is the band between "just infected"
	// and "taken", where it stipples the ground so corruption creeps in rather than snapping from
	// one tile to another.
	if (intensity >= tile_takeover) {
		discard;
	}

	float hold = clamp(intensity / take_hold, 0.0, 1.0);

	// Grain, in roughly the same proportions the ground tiles use for their own speckle, so this
	// sits in the same visual family as the terrain it is replacing.
	float n = hash12(px);
	vec3 col = soil_deep;
	if (n > 0.84) {
		col = flesh;
	} else if (n > 0.55) {
		col = soil_mid;
	}

	// Filaments at half resolution — chunkier than the speckle, so the ground reads as veined and
	// diseased rather than as uniform noise.
	if (hash12(floor(px * 0.5) + 17.0) > 0.94) {
		col = flesh;
	}

	// Freshly claimed ground keeps more of the raw tone, so the advancing frontier stays legible
	// at a glance without any UI marker — the job the old glowing rim did, minus the glow.
	if (hold < 0.55 && n > 0.62) {
		col = flesh;
	}

	// Ordered dither instead of alpha blending: a pixel is either corrupted soil or it is not.
	// This is what stops the edge looking like a soft airbrushed gradient laid over the terrain.
	if (bayer4(px) > hold) {
		discard;
	}

	COLOR = vec4(col, 1.0);
}
