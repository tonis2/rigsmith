module crig;

import cui;
import std::math;

// Actual transparency, not RGB dimming: the mesh must remain visible beneath it.
fn Color rig_overlay_ink(Color ink, float opacity)
{
	Vec4 rgba = (Vec4)ink;
	return (Color){ rgba.x, rgba.y, rgba.z, rgba.w * opacity };
}

// Depth is normalized against the rig, not camera distance, so zooming does not
// change which controls are legible. A flat rig has no artificial far side.
fn float rig_overlay_opacity(float depth, float near_depth, float far_depth,
	bool occluded, bool selected, float strength)
{
	if (selected) return 1.0f;
	float span = far_depth - near_depth;
	float phase = span > 0.00001f ? math::clamp((depth - near_depth) / span, 0.0f, 1.0f) : 0.0f;
	return (0.8f - phase * 0.58f) * (occluded ? 0.45f : 1.0f)
		* math::clamp(strength, MIN_RIG_OVERLAY_STRENGTH, MAX_RIG_OVERLAY_STRENGTH);
}

// A zero-initialised AppState used by a headless check has no loaded config.
// Treat that the same as a first run rather than as a below-range setting.
fn float effective_rig_overlay_strength(AppState* app)
{
	float strength = app.config.rig_overlay_strength;
	return strength >= MIN_RIG_OVERLAY_STRENGTH && strength <= MAX_RIG_OVERLAY_STRENGTH
		? strength : DEFAULT_RIG_OVERLAY_STRENGTH;
}

<*
 Whether this view should fade an overlay point behind the displayed surface.

 Hidden mesh has no surface to hide behind. Wireframe is explicitly the view
 through the surface. Every other view asks `mesh_occluded`, which chooses the
 posed accelerator while a palette is live and the rest picker otherwise.
 Keeping that choice here means dots, bones and labels cannot quietly disagree.
*>
fn bool AppState.rig_overlay_occluded(&self, Vec3 eye, Vec3 point)
{
	return self.show_mesh && !self.wireframe() && self.mesh_occluded(eye, point);
}

// A running clip refreshes one in this many of the overlay's occlusion tests per
// frame; the rest hold their last answer. Six means every dot and bone is
// re-tested within six frames — a tenth of a second at 60fps, which the eye
// cannot separate from per-frame on a body that is moving — while the per-frame
// count of rays cast through the deforming mesh drops to a sixth. See
// `overlay_occluded`.
const uint OCCLUSION_REFRESH_STRIDE = 6;

<*
 `rig_overlay_occluded` for a keyed overlay element, throttled while a clip runs
 or a pose drag moves the body.

 The posed occlusion test is a ray — two, for an interior point — through the
 deforming mesh's BVH, and the viewport asks it once per dot, once per bone and
 once per label, every frame. On a still view that is fine and is answered
 exactly. But a running clip moves the whole body every frame, so every one of
 those hundreds of casts is redone every frame, which is what pins a core down
 and spins the fan up on an otherwise small model.

 So while the clock runs the answers are remembered per element — a dot by its
 id, a bone by its two ids folded together — and only a rotating
 `OCCLUSION_REFRESH_STRIDE`-th of them is recomputed each frame. The dots keep
 moving at the full frame rate; only their behind-the-mesh dimming lags, by at
 most a few frames, and a dot and its label share one answer because they sit at
 the same point.

 `key` must separate the two namespaces: dots pass their id, bones pass
 `overlay_bone_key`.
*>
fn bool AppState.overlay_occluded(&self, uint key, Vec3 eye, Vec3 point)
{
	// No memo (a zero-initialised headless state) or a still view: the exact test,
	// every frame. A pose drag moves the body every frame just as playback does,
	// and is throttled the same way. The still answer is written through so the first frames of
	// playback start from a true picture rather than an empty one.
	bool moving = (self.animating && !self.anim_paused)
		|| (self.drag.dot != 0 && self.drag.verb != DragVerb.PLACE);
	if (!self.occlusion_memo_ready || !moving)
	{
		bool hidden = self.rig_overlay_occluded(eye, point);
		if (self.occlusion_memo_ready) self.occlusion_memo.set(key, hidden);
		return hidden;
	}

	// A running clip: reuse the remembered answer unless this element falls in the
	// slice being refreshed this frame, or has no answer yet.
	if (key % OCCLUSION_REFRESH_STRIDE != self.occlusion_phase)
	{
		if (try hidden = self.occlusion_memo.get(key)) return hidden;
	}
	bool hidden = self.rig_overlay_occluded(eye, point);
	self.occlusion_memo.set(key, hidden);
	return hidden;
}

// A bone's occlusion-memo key, in a namespace disjoint from the dot ids: the top
// bit is set, which no dot id reaches, so a bone and a dot never share a slot.
fn uint overlay_bone_key(uint a, uint b) => 0x80000000u | ((a * 2654435761u + b) & 0x7fffffffu);

// One step of the occlusion refresh cycle, called once per frame by the tick.
// Advancing it here rather than in `Viewport.paint` keeps a split view — which
// paints the overlay once per pane — from spinning the cycle several times a
// frame and refreshing everything at once.
fn void AppState.advance_occlusion_phase(&self)
{
	self.occlusion_phase = (self.occlusion_phase + 1) % OCCLUSION_REFRESH_STRIDE;
}
