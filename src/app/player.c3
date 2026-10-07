<*
 The animation player: a clip from the library, running on the rig on screen.

 `AnimTemplate` says what a clip means at an instant (`anim/animation.c3`); this
 turns that into the two things the renderer needs — a joint palette to skin
 with, and a dot per joint for the overlay to draw at. Timeline drafts use the
 same palette after a parked player hands it over on the first edit.

 **A clip is carried onto this rig, not replayed against its own.** A template
 imported from one figure and played on another is the ordinary case, so
 `AnimTemplate.pose` is handed this rig's skeleton and this rig's joint names
 and works out the rest. That is also what `export_rig` writes, which is what
 makes the exported file play what the preview showed.

 What is playable is a separate question from what is running: `clip_applies`
 asks whether this rig can carry the clip at all, and `clip_playable` widens
 that to "or the pack could supply a rig that can". Both are read by the menus
 and by the library's cells, so a clip that greys out in one greys out in both.
*>
module crig;

import std::math;
import rig;
import std::math::matrix;



<*
  Start playing an animation template.

  Builds the joint skeleton, rebinds the skin, and begins playback.
*>
fn void AppState.start_animation(&self, AnimTemplate template)
{
	self.stop_animation();
	self.swap_clip(template, cut: true);
}

<*
 Put `template` on the rig and start it running.

 The body `start_animation` used to be, with the cut made a choice. Everything
 here is the same either way except the dynamic bones: a cut throws away what the
 last clip left them doing, and a crossfade must not, because inheriting that lag
 is the whole of what makes a fade look like one movement rather than two.

 Does **not** stop what is already running — `start_animation` does that first,
 and `begin_blend` deliberately does not.

 @return `False when the template has no length, or there is no rig to carry it.`
*>
fn bool AppState.swap_clip(&self, AnimTemplate template, bool cut)
{
	// Whatever fade was in flight is over: two clips are as many as this blends,
	// and clearing here rather than at each call site is what stops a stale
	// `fade_from` outliving the clip it was fading out of.
	self.end_blend();

	if (template.keyframes.len == 0 || template.duration <= 0.0f) return false;

	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.@notice("can't animate an empty rig");
		return false;
	}
	RigView view = opened;
	defer view.free(mem);

	if (!self.rebind_skin(&view))
	{
		self.@notice("can't skin this mesh to the rig");
		return false;
	}

	// A transient timeline draft must release the shared palette before the clip
	// fills it again.
	self.stop_deformed_display();

	self.current_anim = template;
	// Whoever knows which clip this was says so afterwards. A template handed in
	// directly — by a test, or later by the scripting surface — came from
	// nowhere in the library and must not claim a cell in it.
	self.current_ref = NO_ANIM;
	self.anim_time = 0.0f;
	self.animating = true;
	// A clip on show is a pose to edit: the header switch follows it to Pose.
	self.stage = POSE_STAGE;
	// Playing, not parked. `park_clip` comes through here and raises it again
	// afterwards, so this is the default rather than an override.
	self.anim_paused = false;
	// A cut: whatever the last clip left the dynamic bones doing is not lag this
	// one may inherit. See `app/sim.c3`.
	if (cut) self.jiggle_reset();
	self.refresh_animation();
	return self.animating;
}

<*
  Stop the current animation and put the mesh back at rest.
*>
fn void AppState.stop_animation(&self)
{
	if (!self.animating) return;
	self.animating = false;
	self.anim_paused = false;
	self.player_pose_live = false;
	self.drop_playback_rig();
	self.current_anim = {};
	self.current_ref = NO_ANIM;
	self.end_blend();
	self.drop_palette();
	// The mesh is back at rest, so the tail has nothing left to lag behind. The
	// sim itself is kept until something wants one again — see `app/sim.c3`.
	self.jiggle_reset();
}

<*
 Play a clip out of the library, fitting the pack's own rig first when there is
 no rig to play it on.

 	`app.play_clip({ pack, clip });`

 **The fit only happens on an empty document.** `apply_preset` adds rather than
 replaces, so fitting over a rig that is already placed would leave two
 skeletons in one document — a clip from another body plan stays out of reach
 instead, and the card's own **Use this rig** is where that decision belongs.

 The fit is an ordinary recorded placement, so the rig and the clip that came
 with it are one Ctrl+Z.

 **And it says so.** Asking for an animation and being given a skeleton is a
 surprise however convenient it is, and it used to happen in silence — which is
 half of why a first run read as arbitrary. The notice names the pack the rig
 came out of, so the user can tell which of three biped packs they now have and
 undo it if it was not the one they wanted.

 @return `False if there is no such clip, or nothing here could play it.`
*>
fn bool AppState.play_clip(&self, AnimRef ref)
{
	if (!self.clip(ref)) return false;
	if (!self.clip_applies(ref))
	{
		if (self.doc.dots.len() > 0) return false;
		if (!self.apply_pack_rig((usz)ref.pack)) return false;

		// After the fit, so the pack is known to have produced one. `apply_pack_rig`
		// writes its own notice about the fit; this replaces it with the sentence
		// that also explains why a rig appeared at all.
		if (AnimPack* fitted = self.pack((usz)ref.pack))
		{
			self.@notice("no rig here yet — fitted the %s skeleton for it",
				fitted.plan.len > 0 ? fitted.plan : fitted.name);
		}
	}
	if (!self.start_animation_ref(ref)) return false;
	self.report_reach(ref);
	return true;
}

<*
 The rig's joints in the words the running clip's pack uses.

 	`rig::Pose pose = anim.pose(mem, &view.skeleton, self.clip_names(&view), time);`

 The whole of the retarget, and the reason it is one line: `AnimTemplate.pose`
 decides what a clip drives by comparing names, so handing it this rig's joints
 spelled the way the pack spells them plays a clip written for another
 vocabulary with nothing in the pose arithmetic changed. See `measure_reach`.

 The rig's own names when there is nothing better — a template started from
 outside the library carries no reference, and a reach measured against a
 different joint order is refused rather than used, which is the one way this
 could put a clip on the wrong bones.

 Borrowed: valid until the next rig edit, which is exactly as long as `view` is.
*>
fn String[] AppState.clip_names(&self, RigView* view)
{
	return self.names_for(view, self.current_ref);
}

<*
 The same, for a clip that is not the one running.

 A crossfade samples two clips at once and they need not come from the same pack:
 fading a Mixamo walk into a hand-authored jump means two vocabularies in one
 frame, and reading the second through the first's reach would drive the wrong
 joints for as long as the fade lasts.
*>
fn String[] AppState.names_for(&self, RigView* view, AnimRef ref)
{
	if (!ref.valid()) return view.names;

	PackReach* reach = self.pack_reach((usz)ref.pack);
	if (!reach || reach.names.len != view.names.len) return view.names;
	return reach.names;
}

<*
 Say how far a clip just started actually reaches, when it does not reach
 everything.

 The disclosure half of playing a clip across two vocabularies. A Mixamo dance on
 a rig with no fingers is a perfectly good walk that will not curl a hand, and
 that is worth one sentence and no dialog: the user asked for the clip, and the
 answer is "yes, minus the hands", not a question.

 **Silent when the clip reaches everything it keys**, which is the ordinary case
 and not news. A notice that fires on every clip is a notice nobody reads by the
 third one.
*>
fn void AppState.report_reach(&self, AnimRef ref)
{
	AnimPack* pack = self.pack((usz)ref.pack);
	AnimTemplate* clip = self.clip(ref);
	PackReach* reach = self.pack_reach((usz)ref.pack);
	if (!pack || !clip || !reach) return;

	ReachGaps gaps = reach_gaps(mem, pack, reach, clip);
	defer gaps.free(mem);
	if (!gaps.present()) return;

	// Two apiece, and a count for the rest. The lists are already the *reduced*
	// ones — the places the rig stops rather than every joint below them — so a
	// clip needing more than two of each is a clip whose gaps are not the news;
	// how much it does drive is. Two also keeps the sentence inside the notice
	// line, which is 160 characters against joint names that run to twenty.
	String below = name_list(mem, gaps.stops, 2);
	String absent = name_list(mem, gaps.missing, 2);
	defer
	{
		if (below.len > 0) alloc::free(mem, below.ptr);
		if (absent.len > 0) alloc::free(mem, absent.ptr);
	}

	usz driven = reach_drives(reach, clip);

	if (below.len > 0 && absent.len > 0)
	{
		self.@notice("%s moves %d of %d joints · the rig has no joints below %s · no %s on the rig",
			clip.name, driven, reach.joints, below, absent);
		return;
	}
	if (below.len > 0)
	{
		self.@notice("%s moves %d of %d joints · the rig has no joints below %s",
			clip.name, driven, reach.joints, below);
		return;
	}
	self.@notice("%s moves %d of %d joints · no %s on the rig", clip.name, driven, reach.joints, absent);
}

<*
 Put a clip on screen at `t` with its clock stopped — what a timeline scrub is.

 	`app.park_clip(ref, 0.31f);`

 Generalised out of `src/mcp/render.c3`, which needed exactly this to photograph
 a clip at an instant without disturbing the player, and which now shares it.

 **Not `stop_animation` followed by a pose.** The palette is rebuilt by the same
 `refresh_animation` playback uses, so a scrubbed frame and a played frame are
 the same picture by construction rather than by two code paths agreeing. It also
 keeps `animating` true, which is what the rest of the app reads to know a clip
 is what the mesh is showing — see `tick_animation` for why that matters.

 Deliberately not `play_clip`: that fits a pack's own rig onto an empty document,
 which is an undoable change to the document and not something dragging a
 playhead should ever make.

 @return `False when the reference names no clip, or the rig will not take it.`
*>
fn bool AppState.park_clip(&self, AnimRef ref, float t)
{
	if (!self.start_animation_ref(ref)) return false;
	self.anim_paused = true;
	self.anim_time = t;
	if (self.current_ref.same(self.editing)) self.edit_time = t;
	self.refresh_animation();
	return true;
}

<*
 Move the playhead of a clip that is already parked.

 The per-mouse-move half of a scrub: `park_clip` is what puts the clip up, and
 this is what dragging does afterwards. Separate because `start_animation_ref`
 resets the jiggle and re-binds the skin, and doing that on every pixel of a drag
 would make the tail snap back sixty times a second.

 @return `False when nothing is parked, so the caller can park first.`
*>
fn bool AppState.scrub_to(&self, float t)
{
	if (!self.animating || !self.anim_paused) return false;
	self.anim_time = t;
	if (self.current_ref.same(self.editing)) self.edit_time = t;
	self.refresh_animation();
	return true;
}

<*
 Stop the clock of a running clip where it is, leaving the clip on screen.

 The transport's pause and the one the brush makes when it opens over a
 running clip: `animating` stays true, so the body keeps its pose, and the
 timeline's playhead lands on the frame that was showing.
*>
fn void AppState.pause_clip(&self)
{
	if (!self.animating || self.anim_paused) return;
	self.anim_paused = true;
	if (self.current_ref.same(self.editing)) self.edit_time = self.anim_time;
}

<*
 Let a parked clip run again, from wherever the playhead was left.
*>
fn void AppState.resume_clip(&self)
{
	if (!self.animating) return;
	// Play at the end means replay, not immediately finish again on the next tick.
	if (self.anim_time >= self.current_anim.duration)
	{
		self.anim_time = 0;
		if (self.current_ref.same(self.editing)) self.edit_time = 0;
		self.refresh_animation();
	}
	self.anim_paused = false;
	self.refresh_ui();
}

<*
 Change clip without a cut: fade out of what is running and into `ref`.

 	`app.begin_blend(walk, 0.2f);`

 What a character driven by input needs and `start_animation` cannot give it —
 that one is a cut by design, resetting the dynamic bones so a new clip does not
 inherit the last one's lag. A crossfade wants exactly the opposite: the tail
 that was swinging on the walk should keep swinging into the run.

 **Falls back to a cut** when there is nothing to fade from, when the clip is
 parked, or when the fade has no length — each of which is a cut in every sense
 that matters, and pretending otherwise would mean a zero-length fade that had to
 be special-cased everywhere downstream.

 Asking for the clip that is already running is answered with silence rather than
 a restart: a script calling `clip("walk")` every frame while a key is held is
 the ordinary way to write one, and restarting would leave the character
 twitching on the first frame of the walk forever.

 @param fade : `Seconds to cross over. Zero or less cuts.`
 @return `False if there is no such clip, or it would not play.`
*>
fn bool AppState.begin_blend(&self, AnimRef ref, float fade)
{
	AnimTemplate* template = self.clip(ref);
	if (!template) return false;

	if (self.current_ref.valid() && self.current_ref.pack == ref.pack
		&& self.current_ref.clip == ref.clip)
	{
		return true;
	}

	if (!self.animating || self.anim_paused || fade <= 0.0f
		|| self.current_anim.keyframes.len == 0)
	{
		return self.start_animation_ref(ref);
	}

	// Read before the swap, which is what overwrites both.
	AnimTemplate outgoing = self.current_anim;
	float outgoing_time = self.anim_time;
	AnimRef outgoing_ref = self.current_ref;

	if (!self.swap_clip(*template, cut: false)) return false;
	self.current_ref = ref;

	// After the swap, because `swap_clip` clears these — it is the one place that
	// can be sure no fade survives a clip change it did not start.
	self.fade_from = outgoing;
	self.fade_from_ref = outgoing_ref;
	self.fade_from_time = outgoing_time;
	self.fade_span = fade;
	self.fade_left = fade;

	// Again, now that there is something to blend: `swap_clip` already refreshed,
	// but it did so with the fade cleared and therefore showed the incoming clip
	// outright — one frame of exactly the jump this exists to remove.
	self.refresh_animation();
	return true;
}

<*
 Forget the clip being faded out of. Idempotent, and cheap enough to call
 wherever a clip changes.

 Nothing is freed: `fade_from` is a shallow copy of a template the library owns,
 the same way `current_anim` is.
*>
fn void AppState.end_blend(&self)
{
	self.fade_from = {};
	self.fade_from_ref = NO_ANIM;
	self.fade_from_time = 0.0f;
	self.fade_left = 0.0f;
	self.fade_span = 0.0f;
}

<*
 Whether a crossfade is in flight.
*>
fn bool AppState.blending(&self)
{
	return self.fade_left > 0.0f && self.fade_span > 0.0f && self.fade_from.keyframes.len > 0;
}

<*
 Start the clip a reference names, and remember which one it was.

 @return `False if there is no such clip, or it would not play.`
*>
fn bool AppState.start_animation_ref(&self, AnimRef ref)
{
	// Read the curves now if this clip was stubbed — the pose about to play is the
	// first thing that needs them.
	self.ensure_clip_imported(ref);
	AnimTemplate* template = self.clip(ref);
	if (!template) return false;

	self.start_animation(*template);
	if (self.animating) self.current_ref = ref;
	return self.animating;
}

<*
 Start the clip at `index` in the pack the library is showing.

 @return `False if there is no such clip, or it would not play.`
*>
fn bool AppState.start_animation_at(&self, usz index)
{
	return self.start_animation_ref({ self.expanded_pack, (int)index });
}

<*
  Advance the animation time and rebuild the palette. Called each frame from
  AppRoot.update, beside the weight debounce.
*>
fn void AppState.tick_animation(&self, float dt)
{
	if (!self.animating) return;

	// Parked: a clip is on screen and its clock is not running. That is what a
	// timeline scrub is, and it is a stop of the *clock* rather than of playback
	// — `animating` stays true, so `skinned()`, `rig_locked()` and the posed
	// overlay all keep behaving as they do while a clip runs. Stopping playback
	// instead would put the mesh back at rest, which is the one thing a scrub
	// must not do.
	if (self.anim_paused) return;
	AnimTemplate anim = self.current_anim;

	// A template with no length has no instant to show and no way to wrap; the
	// subtract-until-inside loop below would never terminate on one.
	if (anim.keyframes.len == 0 || anim.duration <= 0.0f)
	{
		self.stop_animation();
		return;
	}

	dt *= self.anim_preview_speed > 0 ? self.anim_preview_speed : 1.0f;
	self.anim_time += dt;

	// The clip being faded out of keeps running while it fades, so the two are
	// crossing between two moving poses rather than into a frozen one — a fade
	// out of a walk whose legs had stopped mid-stride reads as a stumble.
	if (self.blending())
	{
		self.fade_left -= dt;
		self.fade_from_time += dt;
		AnimTemplate from = self.fade_from;
		if (from.loop && from.duration > 0.0f)
		{
			while (self.fade_from_time >= from.duration) self.fade_from_time -= from.duration;
		}
		if (self.fade_left <= 0.0f) self.end_blend();
	}

	bool preview_loops = self.anim_preview_loop == LOOP
		|| (self.anim_preview_loop == FOLLOW_CLIP && anim.loop);
	if (preview_loops)
	{
		while (self.anim_time >= anim.duration) self.anim_time -= anim.duration;
		if (self.current_ref.same(self.editing)) self.edit_time = self.anim_time;
	}
	else if (self.anim_time >= anim.duration)
	{
		self.anim_time = anim.duration;
		if (self.current_ref.same(self.editing))
		{
			self.edit_time = self.anim_time;
			self.anim_paused = true;
			self.refresh_animation(dt);
			self.refresh_ui();
		}
		else
		{
			self.stop_animation();
		}
		return;
	}
	else if (self.current_ref.same(self.editing))
	{
		self.edit_time = self.anim_time;
	}

	// The same dt the clock just spent, so the physics under the clip runs at the
	// rate the clip does. This is the only caller that passes one.
	self.refresh_animation(dt);
}

<*
  Build the joint palette for the current animation time by interpolating the
  two surrounding keyframes.

  What a template means at a given instant is `AnimTemplate.pose`; the work
  here is turning the document into the two things that needs — a skeleton, and
  a name per joint in the same order.

  The dynamic bones are simulated on top of that, in between: the pose the
  keyframes describe is what they are pulled toward, and the palette below is
  built from the pose they left. See `app/sim.c3`.

  @param dt : `Seconds of real time this refresh covers. Only the clock has one; every other caller is a repaint, and zero is what holds a settled tail in place instead of advancing it.`
*>
fn void AppState.refresh_animation(&self, float dt = 0.0f)
{
	AnimTemplate anim = self.current_anim;
	if (anim.keyframes.len == 0) return;

	self.sync_clip_pins();
	self.drop_palette();

	// Rebuilt only when the rig actually changed — a clip that moves nothing but
	// the clock replays over the same skeleton, so the cache holds and this is a
	// handful of comparisons rather than a fresh skeleton and its lookups every
	// frame. `playback_rig_fresh` is what guarantees the held view still matches.
	if (!self.playback_rig_fresh())
	{
		RigView? opened = self.open_rig(mem);
		if (catch opened)
		{
			self.stop_animation();
			return;
		}
		self.keep_playback_rig(opened);
	}
	// A copy of the cache's handles; read through, never freed here — the cache
	// owns the allocations and releases them on the next rebuild or at teardown.
	RigView view = self.playback_rig;

	// The player owns the binding for as long as it runs. Rebinding is guarded on
	// `skin_stale`, so this is a bool test on the frames nothing changed — and on
	// the ones something did, a rig edit reaches the mesh without stopping
	// playback to be seen.
	self.rebind_skin(&view);

	rig::Pose pose = self.sampled_pose(mem, &view);
	defer pose.free(mem);

	// Kept for the joint panel before the dynamic bones move it: the panel shows
	// the clip's own value for a joint, which is this pose, not the jiggled one —
	// so it reads the joint out of here instead of sampling the whole clip again.
	self.cache_player_pose(pose);

	// Between the sample and the palette, and it has to be: the clip's own pose
	// is what the dynamic bones are pulled toward, and the palette everything
	// below reads has to be the one they left behind.
	self.tick_jiggle(&view, &pose, dt);

	Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch palette) return;
	self.pose_palette = palette;

	// Built here rather than in the viewport because this is the one place that
	// holds all three pieces at once, and because a split view paints the overlay
	// once per pane and would otherwise rebuild the skeleton for each of them.
	self.posed_dots = posed_overlay(mem, &view.skeleton, view.dot_ids, palette);
	self.posed_aims = self.aim_handles(&view, self.current_anim, self.current_ref, self.anim_time, palette, &self.posed_aim_links);
}

<*
 Keep the frame's clip pose so the joint panel can read one joint out of it
 rather than sampling the whole clip a second time. The buffer is reused when it
 is already the right size, so a running clip caches without allocating per
 frame. `player_pose_live` is true only while the clock runs — a paused or
 scrubbed pose is sampled fresh by whoever shows it, so an edit starts from the
 authored value and not from a grounded one.
*>
fn void AppState.cache_player_pose(&self, rig::Pose pose)
{
	if (self.player_pose.rotations.len == pose.rotations.len
		&& self.player_pose.offsets.len == pose.offsets.len)
	{
		foreach (usz i, rotation : pose.rotations) self.player_pose.rotations[i] = rotation;
		foreach (usz i, offset : pose.offsets) self.player_pose.offsets[i] = offset;
	}
	else
	{
		self.player_pose.free(mem);
		self.player_pose = pose.copy(mem);
	}
	self.player_pose_live = self.animating && !self.anim_paused;
}

<*
 Sample one clip through the rig's current joint limits.

 Pass `aimed` to lay the clip's live layers over it, pins first and then aims.

 The clip is always sampled ungrounded first. A constrained knee changes where
 its foot lands, so grounding has to measure the permitted pose rather than the
 raw key and is deliberately last. The returned arrays are temporary evaluated
 data; neither the template nor its keys are rewritten.

 This helper is also the sampling door for timeline drafts and joint UI. The
 player adds crossfade handling in `sampled_pose`, then applies the same limit
 and grounding order to the blended result.

 The caller owns the returned pose.
*>
fn rig::Pose AppState.evaluated_clip_pose(
	&self,
	Allocator allocator,
	RigView* view,
	AnimTemplate clip,
	AnimRef ref,
	float time,
	bool grounded = true,
	bool aimed = false)
{
	// The clip may have been handed in as a deferred stub — read its curves now so
	// a timeline draft or a joint card samples the real motion, not an empty one.
	if (clip.lazy && self.ensure_clip_imported(ref))
	{
		if (AnimTemplate* real = self.clip(ref)) clip = *real;
	}
	String[] names = self.names_for(view, ref);
	rig::Pose pose = clip.pose(allocator, &view.skeleton, names, time, false);
	constrain_pose_to_joint_limits(&self.doc, &view.skeleton, view.dot_ids, &pose);
	if (grounded)
	{
		ground_pose(allocator, &view.skeleton, names, clip.ground, &pose,
			clip.phase_at(time));
	}
	// Last of all, pins and then aims: neither feeds back into a limit or the floor,
	// and a head looks from where the body is held.
	if (aimed)
	{
		self.apply_clip_pins(view, clip, ref, time, &pose);
		self.apply_clip_aims(view, clip, ref, time, &pose);
	}
	return pose;
}

<*
 The pose to show this frame: the running clip, or the two being crossed.

 **The grounding order is the whole reason this is a function.** A clip's own
 `pose` grounds what it returns, and two grounded poses do not average to a
 grounded one — each has a foot planted somewhere, and the midpoint of two
 contacts is a hover. So both sides are sampled with the solve switched off,
 blended, and put on the floor once at the end.

 Which clip's floor spec is used: the incoming one, falling back to the outgoing
 when the incoming names no feet. A fade into a clip that was never grounded
 would otherwise drop the character through the floor for the length of the fade
 and then snap it back.

 The caller owns the returned pose.
*>
fn rig::Pose AppState.sampled_pose(&self, Allocator allocator, RigView* view)
{
	AnimTemplate anim = self.current_anim;
	String[] names = self.clip_names(view);

	if (!self.blending())
	{
		return self.evaluated_clip_pose(allocator, view, anim, self.current_ref,
			self.anim_time, aimed: true);
	}

	AnimTemplate from = self.fade_from;
	String[] from_names = self.names_for(view, self.fade_from_ref);

	// Counted down rather than up, so this is how much of the fade is *spent*.
	float t = 1.0f - self.fade_left / self.fade_span;

	rig::Pose leaving = from.pose(allocator, &view.skeleton, from_names, self.fade_from_time, grounded: false);
	defer leaving.free(allocator);
	rig::Pose arriving = anim.pose(allocator, &view.skeleton, names, self.anim_time, grounded: false);
	defer arriving.free(allocator);

	rig::Pose? mixed = rig::blend_poses(allocator, leaving, arriving, t);
	// Only when the two disagree on joint count, which one skeleton makes
	// impossible — but a fallback that shows the incoming clip beats a frame with
	// no pose at all.
	if (catch mixed)
	{
		return self.evaluated_clip_pose(allocator, view, anim, self.current_ref,
			self.anim_time, aimed: true);
	}

	rig::Pose out = mixed;
	// Limits describe the pose that reaches the renderer, including the midpoint
	// of a crossfade. Clamping the two endpoints only would not guarantee their
	// quaternion blend remains inside independent Euler ranges.
	constrain_pose_to_joint_limits(&self.doc, &view.skeleton, view.dot_ids, &out);
	AnimGround floor = anim.ground.solves() ? anim.ground : from.ground;
	ground_pose(allocator, &view.skeleton, names, floor, &out, anim.phase_at(self.anim_time));
	// Each clip's pins and then targets in proportion to how much of it is showing.
	self.apply_clip_pins(view, from, self.fade_from_ref, self.fade_from_time, &out, 1.0f - t);
	self.apply_clip_pins(view, anim, self.current_ref, self.anim_time, &out, t);
	self.apply_clip_aims(view, from, self.fade_from_ref, self.fade_from_time, &out, null, 1.0f - t);
	self.apply_clip_aims(view, anim, self.current_ref, self.anim_time, &out, null, t);
	return out;
}

<*
 One dot, and where the pose has carried it.

 Keyed by dot id rather than by joint index because the overlay walks the
 document, where a dot has an id and no joint number — the joint order behind
 the palette is BFS output that only `build_skeleton` produces.
*>
struct PosedDot
{
	uint dot;
	Vec3 at;
}

<*
 Where the palette has carried each joint, tagged with the dot it was built
 from.

 A palette entry takes a rest-pose point to where the pose puts it, so a joint's
 own entry applied to its own rest position is where that joint has gone — the
 same arithmetic the skinning pass runs per vertex, at one point per joint.

 The caller owns the returned array. Empty when the three arguments do not
 describe one rig, which leaves the overlay drawing rest positions rather than a
 mixture of two skeletons.

 @param dot_ids : `One dot id per joint, from the build that produced the skeleton.`
*>
fn PosedDot[] posed_overlay(
	Allocator allocator,
	rig::Skeleton* skeleton,
	uint[] dot_ids,
	Matrix4f[] palette) @private
{
	usz count = skeleton.len();
	if (count == 0 || palette.len < count || dot_ids.len < count) return {};

	PosedDot[] posed = alloc::new_array(allocator, PosedDot, (sz)count);
	foreach (usz i, joint : skeleton.joints)
	{
		posed[i] = { .dot = dot_ids[i], .at = joint.transform(palette[i]) };
	}
	return posed;
}

<*
 Where a dot is drawn: where the running clip has carried it, or its own
 position when nothing is playing.

 Every screen-space reading of the rig goes through this — the bones, the dots,
 the names, and the pick test — so what is on screen and what a click lands on
 cannot come apart.

 A linear scan, called per dot per paint. The rig is tens of joints; the map
 that would replace it has to be rebuilt every frame of playback to answer the
 same question.
*>
fn Vec3 Character.dot_position(&self, Dot dot)
{
	foreach (posed : self.posed_dots)
	{
		if (posed.dot == dot.id) return posed.at;
	}
	return dot.position;
}
