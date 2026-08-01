shader_type canvas_item;

// One 32 px quad is instanced for every visible tree and berry patch. The
// instance data chooses a cell in the generated 8x5 atlas, avoiding thousands
// of individual CanvasItem draw commands.
const vec2 ATLAS_CELLS = vec2(8.0, 5.0);

void vertex() {
	UV = (UV + INSTANCE_CUSTOM.rg) / ATLAS_CELLS;
}
