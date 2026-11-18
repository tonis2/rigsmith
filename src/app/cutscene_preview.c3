<*
 The cutscene preview: every actor stood where the active cutscene has it at
 `cut_time`, playing the clip it plays then. Leaving puts each character back.
 While it plays a strip fades in from the one before, as the game's player does;
 a scrubbed frame is a cut, as the game's seek is.
*>
module crig;

import rig;
import std::math;

<* What a character was showing before the preview, to go back to. *>
struct CutKept
{
	uint character;
	bool animating;
	AnimRef playing;
	float time;
	bool paused;
	bool loops;
	AnimRef editing;
	float edit_time;
	EditStage stage;
}

<* Whether the preview is posing the actors now. *>
fn bool AppState.cutscene_previewing(&self) => self.cut_preview && self.cutscene() != null;

<*
 Turn the preview on or off. On, each character's own clip and time are kept and the
 actors take the cutscene's poses; off, each goes back exactly as it was.

 @return "False when there is no cutscene to preview"
*>
fn bool AppState.set_cutscene_preview(&self, bool on)
{
	if (!on)
	{
		self.leave_cutscene_preview();
		return true;
	}
	if (!self.cutscene()) return false;
	if (self.cut_preview) return true;
	if (!self.focus_may_move()) return false;
	self.end_focus_gestures();
	if (!self.cut_kept.is_initialized()) self.cut_kept.init(mem);
	self.cut_kept.clear();
	for (usz i = 0; i < self.character_count(); i++)
	{
		self.@as_character(i)
		{
			// An unkeyed pose is let go, as moving the playhead lets it go.
			(void)self.prepare_timeline_navigation();
			self.cut_kept.push({
				.character = self.id,
				.animating = self.animating,
				.playing = self.current_ref,
				.time = self.anim_time,
				.paused = self.anim_paused,
				.loops = self.current_anim.loop,
				.editing = self.editing,
				.edit_time = self.edit_time,
				.stage = self.stage,
			});
		};
	}
	self.cut_kept_clock = self.scene_time;
	self.cut_kept_running = self.scene_running;
	self.cut_preview = true;
	self.apply_cutscene();
	return true;
}

<* Every character back to its own clip, time and place. *>
fn void AppState.leave_cutscene_preview(&self)
{
	self.cut_playing = false;
	if (!self.cut_preview) return;
	self.cut_preview = false;
	for (usz i = 0; i < self.character_count(); i++)
	{
		self.@as_character(i)
		{
			self.staged = false;
			foreach (kept : self.cut_kept)
			{
				if (kept.character != self.id) continue;
				self.put_back(kept);
				break;
			}
			self.drop_cut_shown();
		};
	}
	self.cut_kept.clear();
	self.scene_time = self.cut_kept_clock;
	self.scene_running = self.cut_kept_running;
}

fn void AppState.put_back(&self, CutKept kept)
{
	if (kept.animating && kept.playing.valid() && self.start_animation_ref(kept.playing))
	{
		self.current_anim.loop = kept.loops;
		self.anim_time = kept.time;
		self.anim_paused = kept.paused;
		self.refresh_animation();
	}
	else
	{
		self.stop_animation();
	}
	self.editing = kept.editing;
	self.edit_time = kept.edit_time;
	self.stage = kept.stage;
}

<*
 Move the cutscene's playhead to `t`, inside its length, posing the actors when the preview is on.
*>
fn void AppState.show_cutscene_at(&self, float t)
{
	// While a one-off is edited the cutscene's playhead is its clip's: moving one moves the other.
	if (self.one_off_here() && self.one_off_seek(t)) return;
	Cutscene* cutscene = self.cutscene();
	float end = cutscene ? math::max(cutscene.duration, 0.0f) : 0.0f;
	self.cut_time = math::is_finite(t) ? math::clamp(t, 0.0f, end) : 0.0f;
	if (self.cut_preview) self.apply_cutscene();
}

<*
 Play or pause the cutscene. Playing turns the preview on, and from the end starts over.

 @return "False when there is no cutscene"
*>
fn bool AppState.play_cutscene(&self, bool play)
{
	Cutscene* cutscene = self.cutscene();
	if (!cutscene) return false;
	if (!play)
	{
		self.cut_playing = false;
		return true;
	}
	(void)self.back_to_cutscene();
	if (!self.set_cutscene_preview(true)) return false;
	if (self.cut_time >= cutscene.duration) self.show_cutscene_at(0.0f);
	self.cut_playing = true;
	return true;
}

<*
 The cutscene's clock, once a frame.

 @return "Whether the actors moved, so the views repaint"
*>
fn bool AppState.tick_cutscene(&self, float dt)
{
	if (!self.cut_playing || !self.cutscene_previewing()) return false;
	Cutscene* cutscene = self.cutscene();
	float next = self.cut_time + dt;
	if (next >= cutscene.duration)
	{
		next = cutscene.duration;
		self.cut_playing = false;
	}
	self.show_cutscene_at(next);
	return true;
}

<* Every actor of the active cutscene posed at `cut_time`; a character no actor plays is left as it is. *>
fn void AppState.apply_cutscene(&self)
{
	Cutscene* cutscene = self.cutscene();
	if (!cutscene || !self.cut_preview) return;
	self.refresh_cut_homes(cutscene);
	@pool()
	{
		CutCurve[] curves = cutscene_curves(tmem, cutscene);
		for (usz i = 0; i < self.character_count(); i++)
		{
			int actor = cutscene.actor_by_row(self.character(i).actor_row);
			if (self.character(i).actor_row.len == 0 || actor < 0)
			{
				self.character(i).staged = false;
				continue;
			}
			CutActorPose pose = cutscene_actor_shown(cutscene, curves, (usz)actor, self.cut_time);
			CutStrip* strip = pose.strip >= 0 ? &cutscene.actors[actor].strips[pose.strip] : null;
			// A one-off being edited shows through the character's own player; it only stands here.
			if (self.one_off.open && self.character(i).id == self.one_off.character)
			{
				self.character(i).staged = true;
				self.character(i).staged_place = { pose.position, pose.rotation };
				continue;
			}
			CutOneOff* one = strip ? cutscene.one_off_of((usz)actor, strip) : null;
			// The player fades between strips only as it plays; a scrubbed frame is a cut, as in the game.
			CutFade fade = self.cut_playing ? cutscene_actor_fade(cutscene, curves, (usz)actor, self.cut_time, pose)
				: (CutFade){ .strip = -1, .weight = 1.0f };
			self.@as_character(i)
			{
				self.staged = true;
				self.staged_place = { pose.position, pose.rotation };
				bool faded = self.set_cut_fade(cutscene, (usz)actor, fade);
				if (one)
				{
					self.show_cut_one_off(strip, one, pose, faded);
				}
				else
				{
					self.show_cut_clip(strip, pose, faded);
				}
			};
		}
	};
}

<*
 A one-off strip's clip at the pose's clip time: a copy of the cutscene's, made again when that
 changes, played as a clip of no pack.
*>
fn void AppState.show_cut_one_off(&self, CutStrip* strip, CutOneOff* one, CutActorPose pose, bool refade = false)
{
	bool fresh = self.cut_shown.keyframes.len > 0 && self.cut_shown_from == self.cut_revision
		&& self.cut_shown.name == one.clip.name;
	if (!fresh)
	{
		self.stop_animation();
		self.drop_cut_shown_clip();
		self.cut_shown = clip_copy(mem, one.clip);
		self.cut_shown.compile_tracks(mem);
		self.cut_shown_from = self.cut_revision;
	}
	bool showing = self.animating && self.current_anim.keyframes.ptr == self.cut_shown.keyframes.ptr;
	if (!showing)
	{
		self.start_animation(self.cut_shown);
		if (!self.animating) return;
	}
	float local = cut_clip_local(pose.clip_time, self.current_anim.duration, strip.loop);
	self.anim_paused = true;
	if (showing && self.anim_time == local && !refade) return;
	self.anim_time = local;
	self.refresh_animation();
}

<*
 Set the cross-fade the focus shows out of, from `fade`: the outgoing strip's clip, its own or a
 copy of a one-off, at its time. None for a clip it lacks.

 @return "Whether the fade changed, so the pose is shown again"
*>
fn bool AppState.set_cut_fade(&self, Cutscene* c, usz actor, CutFade fade)
{
	bool was = self.cut_fading;
	if (fade.strip < 0)
	{
		self.cut_fading = false;
		return was;
	}
	CutStrip* o = &c.actors[actor].strips[fade.strip];
	CutOneOff* one = c.one_off_of(actor, o);
	AnimTemplate* from;
	AnimRef ref = NO_ANIM;
	if (one)
	{
		if (self.cut_fade_copy.keyframes.len == 0 || self.cut_fade_copy_from != self.cut_revision || self.cut_fade_copy.name != one.clip.name)
		{
			self.cut_fade_copy.free(mem);
			self.cut_fade_copy = clip_copy(mem, one.clip);
			self.cut_fade_copy.compile_tracks(mem);
			self.cut_fade_copy_from = self.cut_revision;
		}
		from = &self.cut_fade_copy;
	}
	else if (!o.one_off)
	{
		from = self.bound_clip_named(o.clip, &ref);
	}
	if (!from)
	{
		self.cut_fading = false;
		return was;
	}
	self.cut_fading = true;
	self.cut_fade_ref = ref;
	self.cut_fade_time = cut_clip_local(fade.clip_time, from.duration, o.loop);
	self.cut_fade_weight = fade.weight;
	return true;
}

<*
 The pose on show mixed out of the clip it fades from, by the incoming clip's share: what
 `refresh_animation` lays between the sampled pose and the palette. A joint the incoming clip
 does not key keeps the outgoing pose until the fade is done, as in the game.
*>
fn void AppState.mix_cut_fade(&self, RigView* view, rig::Pose* pose)
{
	if (!self.cut_fading || !self.staged) return;
	AnimTemplate* from = self.cut_fade_ref.valid() ? self.clip(self.cut_fade_ref) : &self.cut_fade_copy;
	if (!from || from.keyframes.len == 0) return;
	rig::Pose out = self.evaluated_clip_pose(mem, view, *from, self.cut_fade_ref, self.cut_fade_time, aimed: true);
	defer out.free(mem);
	if (out.rotations.len != pose.rotations.len) return;
	String[] names = self.names_for(view, self.current_ref);
	bool[] keyed = alloc::new_array(mem, bool, (sz)pose.rotations.len);
	defer free(keyed);
	foreach (usz j, &k : keyed)
	{
		if (j >= names.len || names[j].len == 0) continue;
		foreach (&key : self.current_anim.keyframes) foreach (dot : key.dots) if (dot.joint_name == names[j]) *k = true;
		foreach (&pin : self.current_anim.pins) if (pin.joint == names[j]) *k = true;
	}
	blend_poses(pose, out, self.cut_fade_weight, keyed);
}

<*
 The strip's clip at the pose's clip time, parked; the rest pose for no strip or a
 clip this character lacks.
*>
fn void AppState.show_cut_clip(&self, CutStrip* strip, CutActorPose pose, bool refade = false)
{
	AnimRef ref = NO_ANIM;
	if (!strip || !self.bound_clip_named(strip.clip, &ref))
	{
		self.stop_animation();
		return;
	}
	bool showing = self.animating && self.current_ref.same(ref);
	if (!showing && !self.start_animation_ref(ref))
	{
		self.stop_animation();
		return;
	}
	float local = cut_clip_local(pose.clip_time, self.current_anim.duration, strip.loop);
	self.anim_paused = true;
	if (showing && self.anim_time == local && !refade) return;
	self.anim_time = local;
	if (self.current_ref.same(self.editing)) self.edit_time = local;
	self.refresh_animation();
}
