<*
 Layers as strips (app/strips.c3): a piece laid on a clip's track plays at its
 place, a linked one follows its source through edits, renames and deletes, and
 strips move, trim and speed up as one undo step each.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::strips`
*>
module crig_tests::strips;

import crig;
import rig;
import std::collections::object;
import std::core::test;
import std::encoding::json;
import std::math;
import std::math::vector;
import std::math::quaternion;

const Vec3 X = { 1, 0, 0 };
const Vec3 Y = { 0, 1, 0 };

fn AnimKeyframe key_of(float time, String joint, Vec3 axis, float angle)
{
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
	dots[0] = { .joint_name = joint.copy(mem), .axis = axis, .angle = angle, .channels = ROTATION };
	return { .time = time, .dots = dots };
}

fn AnimTemplate clip_of(String name, float duration, bool loop, AnimKeyframe[] keys)
{
	return { .name = name.copy(mem), .duration = duration, .keyframes = keys, .loop = loop, .owned = true };
}

fn AnimKeyframe[] three_keys(String joint, Vec3 axis, float peak, float duration)
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 3);
	keys[0] = key_of(0.0f, joint, axis, 0.0f);
	keys[1] = key_of(duration * 0.5f, joint, axis, peak);
	keys[2] = key_of(duration, joint, axis, 0.0f);
	return keys;
}

// root - a - b - c: "Walk" turns a, "Bend" (one second, not looping) turns b.
struct Strips
{
	crig::AppState app;
	AnimRef walk;
	AnimRef bend;
}

fn void Strips.open(&self)
{
	self.app = crig::new_app({});
	uint root = self.app.doc.add_dot({ 0, 1, 0 }, "root");
	uint a = self.app.doc.add_dot({ 0, 0.8f, 0 }, "a");
	uint b = self.app.doc.add_dot({ 0, 0.6f, 0 }, "b");
	uint c = self.app.doc.add_dot({ 0, 0.4f, 0 }, "c");
	self.app.doc.connect(root, a);
	self.app.doc.connect(a, b);
	self.app.doc.connect(b, c);
	self.app.doc.root_id = root;
	self.bend = self.app.author_clip(clip_of("Bend", 1.0f, false, three_keys("b", X, 0.8f, 1.0f)));
	self.walk = self.app.author_clip(clip_of("Walk", 2.0f, true, three_keys("a", Y, 0.3f, 2.0f)));
	self.app.undo_stack.clear();
}

fn void Strips.close(&self) => self.app.free();

fn AnimRef Strips.named(&self, String name) => self.app.clip_named_in_authored(name);

// The turn of joint `j` in the clip's live pose at `time`.
fn Quaternionf Strips.turn(&self, AnimRef ref, usz j, float time)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = self.app.evaluated_clip_pose(mem, &view, *self.app.clip(ref), ref, time, false);
	defer pose.free(mem);
	return pose.rotations[j];
}

fn bool near_turn(Quaternionf a, Quaternionf b, float tolerance = 1.0e-4f)
{
	return 1.0f - math::abs(a.v.dot(b.v)) < tolerance;
}

fn usz Strips.lay_bend(&self, float at)
{
	crig::Piece piece = { .kind = CLIP, .clip = self.named("Bend") };
	sz laid = self.app.place_piece(self.named("Walk"), piece, at, 99);
	test::@check(laid >= 0, "the piece would not lay: %s", self.app.notice());
	return (usz)laid;
}

<*
 A piece laid at half a second plays its own first frame there and its middle
 half a second later, on a track of its own above the clip's own layers.
*>
fn void a_linked_piece_plays_at_its_place() @test
{
	Strips s;
	s.open();
	defer s.close();
	usz at = s.lay_bend(0.5f);
	AnimTemplate* walk = s.app.clip(s.named("Walk"));
	AnimLayer* strip = &walk.layers[at];
	test::@check(strip.source == "Bend" && strip.offset == 0.5f && strip.start == 0.5f && strip.end == 1.5f,
		"the strip is not Bend placed at 0.5..1.5: %s %s %s..%s", strip.source, strip.offset, strip.start, strip.end);
	test::@check(strip.fit == KEEP && strip.mode == OVERRIDE, "a one-pass piece should keep its seconds and override");

	Quaternionf bend_peak = s.turn(s.named("Bend"), 2, 0.5f);
	test::@check(near_turn(s.turn(s.named("Walk"), 2, 1.0f), bend_peak), "the piece's middle is not at 1.0s");
	test::@check(near_turn(s.turn(s.named("Walk"), 2, 0.25f), quaternion::IDENTITY), "the piece played before its start");
	test::@check(s.app.undo() && s.app.clip(s.named("Walk")).layers.len == 0, "one undo did not take the piece back");
}

<*
 Editing the source rebuilds every strip playing it, in the same undo step.
*>
fn void editing_the_source_updates_the_piece_in_one_undo_step() @test
{
	Strips s;
	s.open();
	defer s.close();
	s.lay_bend(0.0f);
	Quaternionf before = s.turn(s.named("Walk"), 2, 0.5f);
	s.app.land_clip(s.named("Bend"), crig::clip_with_key(mem, *s.app.clip(s.named("Bend")), key_of(0.5f, "b", X, 1.4f)));
	Quaternionf after = s.turn(s.named("Walk"), 2, 0.5f);
	test::@check(!near_turn(before, after), "the strip did not follow the edit of its source");
	test::@check(near_turn(after, s.turn(s.named("Bend"), 2, 0.5f)), "the strip does not play the edited source");
	test::@check(s.app.undo(), "the edit did not undo");
	test::@check(near_turn(s.turn(s.named("Walk"), 2, 0.5f), before), "one undo left the strip edited");
}

<*
 A clip cannot play itself: laying Walk into Bend once Bend plays in Walk is
 refused, and so is a clip into itself.
*>
fn void a_piece_that_would_play_itself_is_refused() @test
{
	Strips s;
	s.open();
	defer s.close();
	s.lay_bend(0.0f);
	crig::Piece walk = { .kind = CLIP, .clip = s.named("Walk") };
	test::@check(s.app.place_piece(s.named("Bend"), walk, 0.0f, 0) < 0, "Walk was laid into Bend, which Walk plays");
	test::@check(s.app.place_piece(s.named("Walk"), walk, 0.0f, 0) < 0, "Walk was laid into itself");
	test::@check(s.app.clip(s.named("Bend")).layers.len == 0, "a refused piece left a layer");
}

<*
 Renamed, the source is still what its strips play; deleted, they keep what it
 last was.
*>
fn void renaming_and_deleting_the_source_keep_the_piece() @test
{
	Strips s;
	s.open();
	defer s.close();
	usz at = s.lay_bend(0.0f);
	Quaternionf played = s.turn(s.named("Walk"), 2, 0.5f);
	s.app.land_clip(s.named("Bend"), crig::clip_copy(mem, *s.app.clip(s.named("Bend")), "Bow"));
	test::@check(s.app.clip(s.named("Walk")).layers[at].source == "Bow", "the strip did not follow the rename");
	test::@check(s.app.delete_authored_clip("Bow"), "the source would not delete");
	s.app.undo_stack.commit();
	AnimLayer* kept = &s.app.clip(s.named("Walk")).layers[at];
	test::@check(kept.source.len == 0 && kept.keyframes.len > 0, "a deleted source left its strip linked or empty");
	test::@check(near_turn(s.turn(s.named("Walk"), 2, 0.5f), played), "the strip lost its motion with its source");
	test::@check(s.app.undo() && s.app.clip(s.named("Walk")).layers[at].source == "Bow", "undo did not relink the strip");
}

<*
 Moving a strip carries what it plays; moving it onto a track where it would
 overlap another strip is refused.
*>
fn void moving_a_strip_carries_its_motion_and_refuses_an_overlap() @test
{
	Strips s;
	s.open();
	defer s.close();
	usz first = s.lay_bend(0.0f);
	sz moved = s.app.move_strip(s.named("Walk"), first, 0.25f, s.app.clip(s.named("Walk")).layers[first].track);
	test::@check(moved >= 0, "the strip would not move: %s", s.app.notice());
	AnimLayer* strip = &s.app.clip(s.named("Walk")).layers[(usz)moved];
	test::@check(strip.offset == 0.25f && strip.start == 0.25f && strip.end == 1.25f, "the strip did not move by a quarter second");
	test::@check(near_turn(s.turn(s.named("Walk"), 2, 0.75f), s.turn(s.named("Bend"), 2, 0.5f)), "the motion did not move with the strip");

	// A wave on a track of its own, then onto the strip's track over it.
	crig::Piece wave = { .kind = WAVE };
	sz other = s.app.place_piece(s.named("Walk"), wave, 0.5f, 99);
	test::@check(other >= 0, "the wave would not lay");
	uint track = s.app.clip(s.named("Walk")).layers[(usz)moved].track;
	sz edits = s.app.undo_stack.cursor;
	test::@check(s.app.move_strip(s.named("Walk"), (usz)other, 0.0f, track) < 0, "an overlapping move landed");
	test::@check(s.app.undo_stack.cursor == edits, "a refused move left an undo step");

	// Two strips that do not overlap share a track.
	test::@check(s.app.trim_strip(s.named("Walk"), (usz)other, 1.5f, 2.0f), "the wave would not trim");
	test::@check(s.app.move_strip(s.named("Walk"), (usz)other, 0.0f, track) >= 0, "a strip did not join a free stretch of a track");
	test::eq(s.app.clip(s.named("Walk")).track_count(), (uint)1);
}

<*
 A piece played at half speed takes twice as long: its middle lands a second in.
*>
fn void a_strip_sped_down_plays_its_seconds_longer() @test
{
	Strips s;
	s.open();
	defer s.close();
	usz at = s.lay_bend(0.0f);
	test::@check(s.app.speed_strip(s.named("Walk"), at, 2.0f), "the strip would not slow");
	AnimLayer* strip = &s.app.clip(s.named("Walk")).layers[at];
	test::@check(math::abs(strip.speed - 0.5f) < 1.0e-5f && strip.end == 2.0f, "the strip is not at half speed to 2s");
	test::@check(near_turn(s.turn(s.named("Walk"), 2, 1.0f), s.turn(s.named("Bend"), 2, 0.5f)), "half speed did not put the middle at 1s");
	test::@check(s.app.set_strip_fades(s.named("Walk"), at, 0.5f, 5.0f), "the fades would not land");
	strip = &s.app.clip(s.named("Walk")).layers[at];
	test::@check(strip.fade_in == 0.5f && strip.fade_out == 1.5f, "the fades were not clamped to the strip");
}

<*
 Retimed, a placed piece keeps playing the same stretch of the clip; flattened,
 the clip plays as it did live.
*>
fn void a_retime_moves_a_placed_piece_and_a_flatten_matches_it() @test
{
	Strips s;
	s.open();
	defer s.close();
	s.lay_bend(0.5f);
	AnimTemplate slow = crig::clip_retimed(mem, *s.app.clip(s.named("Walk")), 4.0f);
	defer slow.free(mem);
	AnimLayer* strip = &slow.layers[slow.layers.len - 1];
	test::@check(strip.offset == 1.0f && math::abs(strip.speed - 0.5f) < 1.0e-5f, "the retime left the piece at %s, speed %s", strip.offset, strip.speed);

	crig::RigView view = s.app.open_rig(mem)!!;
	defer view.free(mem);
	AnimTemplate* walk = s.app.clip(s.named("Walk"));
	AnimTemplate flat = crig::clip_flattened(mem, *walk, &view.skeleton, view.names);
	defer flat.free(mem);
	for (float t = 0.0f; t <= 2.0f; t += 0.125f)
	{
		rig::Pose live = walk.pose(mem, &view.skeleton, view.names, t, false);
		defer live.free(mem);
		rig::Pose baked = flat.pose(mem, &view.skeleton, view.names, t, false);
		defer baked.free(mem);
		foreach (usz j, turn : live.rotations)
		{
			test::@check(near_turn(turn, baked.rotations[j], 1.0e-3f), "joint %d differs at %ss after flattening", j, t);
		}
	}
}

<*
 A strip's place survives the layer JSON both the sidecar and the wire read.
*>
fn void strip_fields_round_trip_through_the_layer_json() @test
{
	AnimLayer layer = crig::anim_layer_defaults("piece".copy(mem));
	defer layer.free(mem);
	layer.kind = KEYED;
	layer.length = 1.0f;
	layer.fit = REPEAT;
	layer.track = 3;
	layer.offset = 0.75f;
	layer.speed = 1.5f;
	layer.source = "Bend".copy(mem);
	DString text = dstring::new(mem);
	defer text.free();
	text.append_char('{');
	crig::append_layer_fields(&text, &layer);
	text.append_char('}');
	Object* parsed = json::parse(mem, text.str_view())!!;
	defer parsed.free();
	AnimLayer back = crig::anim_layer_defaults("");
	defer back.free(mem);
	test::@check(crig::read_layer_fields(parsed, mem, &back, null), "the layer did not read back: %s", text);
	test::@check(back.track == 3 && back.offset == 0.75f && back.speed == 1.5f && back.source == "Bend",
		"the strip fields did not round trip: %s", text);
}

fn String call_set_layer(Strips* s, String text, bool* ok)
{
	Object* args = json::parse(mem, text)!!;
	defer args.free();
	DString detail = dstring::new(mem);
	defer detail.free();
	String? out = crig::set_layer_json(&s.app, args, &detail);
	if (catch out)
	{
		*ok = false;
		return detail.copy_str(mem);
	}
	*ok = true;
	return out;
}

<*
 The wire lays a piece, moves it and makes it local, one undo step each.
*>
fn void set_layer_lays_moves_and_localises_a_piece() @test
{
	Strips s;
	s.open();
	defer s.close();
	bool ok;
	String laid = call_set_layer(&s, `{"clip":"Walk","op":"piece","piece":{"clip":"Bend"},"at":0.5}`, &ok);
	defer laid.free(mem);
	test::@check(ok && laid.contains(`"source":"Bend"`), "piece refused or unreported: %s", laid);
	String moved = call_set_layer(&s, `{"clip":"Walk","op":"move_strip","name":"Bend","at":0.75}`, &ok);
	defer moved.free(mem);
	test::@check(ok && s.app.clip(s.named("Walk")).layers[0].offset == 0.75f, "move_strip refused or wrong: %s", moved);
	String local = call_set_layer(&s, `{"clip":"Walk","op":"make_local","name":"Bend"}`, &ok);
	defer local.free(mem);
	test::@check(ok && s.app.clip(s.named("Walk")).layers[0].source.len == 0, "make_local refused or still linked: %s", local);
	String refused = call_set_layer(&s, `{"clip":"Walk","op":"replace","name":"Bend","layer":{"source":"Bend"}}`, &ok);
	defer refused.free(mem);
	test::@check(!ok, "replace set a source");
	test::@check(s.app.undo() && s.app.clip(s.named("Walk")).layers[0].source == "Bend", "undo did not relink");
}
