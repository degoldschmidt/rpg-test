shader_type spatial;
// Crowd NPCs: vertex animation texture playback (see scripts/crowd/crowd_vat.gd).
// Per instance: COLOR = skin color, INSTANCE_CUSTOM = (stroll phase 0..1, stroll weight 0..1,
// idle phase 0..1, unused).

uniform sampler2D pos_tex : filter_nearest, repeat_disable;
uniform sampler2D nrm_tex : filter_nearest, repeat_disable;
uniform int walk_frames = 24;
uniform int idle_frames = 16;

varying vec3 tint;

vec3 fetch(sampler2D tex, int vid, int row) {
	return texelFetch(tex, ivec2(vid, row), 0).xyz;
}

void vertex() {
	int vid = int(UV2.x + 0.5);
	float wf = fract(INSTANCE_CUSTOM.x) * float(walk_frames);
	int w0 = int(wf) % walk_frames;
	int w1 = (w0 + 1) % walk_frames;
	float wt = fract(wf);
	float idf = fract(INSTANCE_CUSTOM.z) * float(idle_frames);
	int i0 = int(idf) % idle_frames;
	int i1 = (i0 + 1) % idle_frames;
	float it = fract(idf);
	i0 += walk_frames;
	i1 += walk_frames;
	float b = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
	vec3 pw = mix(fetch(pos_tex, vid, w0), fetch(pos_tex, vid, w1), wt);
	vec3 pi = mix(fetch(pos_tex, vid, i0), fetch(pos_tex, vid, i1), it);
	vec3 nw = mix(fetch(nrm_tex, vid, w0), fetch(nrm_tex, vid, w1), wt);
	vec3 ni = mix(fetch(nrm_tex, vid, i0), fetch(nrm_tex, vid, i1), it);
	VERTEX = mix(pi, pw, b);
	NORMAL = normalize(mix(ni, nw, b));
	tint = COLOR.rgb;
}

void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 0.6;
}
