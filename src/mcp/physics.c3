<*
 The two physics tools: `set_secondary_motion`, which says which chains of
 bones the physics owns and how each behaves, and `bake_physics`, which runs it
 over a clip and writes down what happened.

 They are two halves of one thing and the split is the whole design. **Physics is
 a property of the rig, not of a clip** — a tail is given secondary motion once
 and then swings under everything that plays — so `set_secondary_motion` writes
 onto the document beside `reach` and the attachments, and every clip inherits
 it. And physics *runs* only while the player is running, so a tail that swings
 on screen swings nowhere else: not in `render`, not in a saved pack, not in an
 exported glTF, none of which have a solver in them. `bake_physics` is the
 crossing — one clip's worth of that simulation turned into ordinary keyframes,
 after which every path crig already has carries it unchanged.

 So the order is `set_secondary_motion` → `play` to watch it → `bake_physics` →
 `save_pack` or an export, and the middle two are where a caller finds out that
 a flexibility near 1 is a rope and one near 0 is a stick.

 A chain is stated as a root and a tip and a handful of values in user terms —
 preset, flexibility, damping, gravity, collide — and expanded to the solver's
 per-bone numbers only at the boundary; see `core/secondary.c3`.

 Handlers only, like clip.c3 and body.c3: the solver is `anim/jiggle.c3`, the bake
 is `anim/bake.c3`, neither of which knows what JSON is, and the registration is
 server.c3's.
*>
module crig;

import rig;
import std::collections::object;
import std::math;

faultdef PHYSICS_REFUSED;

// The rates a bake will take. The top is the solver's own substep, below which
// there is nothing more to record; the bottom is a sample every ten seconds,
// which is past the point of being an animation at all.
const double BAKE_FASTEST_HZ @local = 120.0;
const double BAKE_SLOWEST_HZ @local = 0.1;

// Turns of the cycle a chain may be given to settle before recording starts.
// Two is the default and enough for anything; the cap is where a bake would
// spend more time warming up than recording without saying why.
const double BAKE_MOST_SETTLE @local = 32.0;

const String BAKE_PHYSICS_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip to simulate. Clip name, or \"Pack/Clip\" to say which pack. A bare name two packs share is an error."},
	"name":{"type":"string","description":"What to call the baked clip. Defaults to the source's name with \" baked\" after it. A clip of that name in the Authored pack is replaced."},
	"hz":{"type":"number","description":"Samples per second. Default 30. The solver runs at 120 whatever this says, so the rate is snapped to a divisor of it — 120, 60, 40, 30, 24, 20, 15 and 12 land exactly — and the answer reports which one was used."},
	"settle_loops":{"type":"number","description":"How many turns of the cycle to run unrecorded before recording starts, so the chain is swinging rather than starting from its bind pose. Default 2. Ignored for a clip that does not loop, which begins where its author said it begins."}
},"required":["clip"]}`;

<*
 Simulate a clip's dynamic bones and land the result as a clip of its own.

 	`String answer = bake_physics_json(app, args, &detail)!;`

 Everything is checked before anything is built: the arguments, then the rig,
 then that the rig has something dynamic on it, then the clip. A refusal
 therefore leaves the document exactly as it found it, which matters more here
 than usual — a bake is undoable, so a half-done one would be a history entry
 nobody asked for.

 The sim is private and freed before returning. The one running under the
 viewport is deliberately not borrowed: its particles carry the display's own
 history — where the tail happened to be when somebody paused — and a bake has
 to be a function of the clip and the rig alone.

 @param detail : `Filled with what was refused and what would have been taken instead.`
 @return? PHYSICS_REFUSED : `The reason is in detail.`
*>
fn String? bake_physics_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `bake_physics takes an object: {"clip": name, "name": what to call the baked copy, "hz": samples per second, "settle_loops": unrecorded cycles first}`)) return PHYSICS_REFUSED~;

	String wanted;
	if (!required_string(args, "clip", &wanted, detail, `bake_physics needs "clip": the name of the clip to simulate. get_scene lists every pack and clip.`)) return PHYSICS_REFUSED~;

	String label = "";
	if (member(args, "name") != null)
	{
		String? given = args.get_string("name");
		if (catch given)
		{
			detail.append_string(`"name" must be a string: what to call the baked clip. Leave it out and the source's name with " baked" after it is used.`);
			return PHYSICS_REFUSED~;
		}
		label = given;
	}

	double hz = (double)BAKE_DEFAULT_HZ;
	if (member(args, "hz") != null)
	{
		double? given = args.get_float("hz");
		if (catch given)
		{
			detail.append_string(`"hz" must be a number: how many samples a second to record. 30 is the default.`);
			return PHYSICS_REFUSED~;
		}
		hz = given;
		if (hz < BAKE_SLOWEST_HZ || hz > BAKE_FASTEST_HZ)
		{
			detail.appendf(
				`"hz" is %.9g. It has to be between %.9g and %.9g — the top is the solver's own substep, past which there is nothing more to record. The rate is then snapped to a divisor of 120, so 120, 60, 40, 30, 24, 20, 15 and 12 land exactly; 30 is the default.`,
				hz, BAKE_SLOWEST_HZ, BAKE_FASTEST_HZ);
			return PHYSICS_REFUSED~;
		}
	}

	double settle = (double)BAKE_DEFAULT_SETTLE;
	if (member(args, "settle_loops") != null)
	{
		double? given = args.get_float("settle_loops");
		if (catch given)
		{
			detail.append_string(`"settle_loops" must be a number: how many turns of the cycle to run before recording starts. 2 is the default.`);
			return PHYSICS_REFUSED~;
		}
		settle = given;
		if (settle < 0 || settle > BAKE_MOST_SETTLE)
		{
			detail.appendf(
				`"settle_loops" is %.9g. It has to be between 0 and %.9g; 2 is the default and enough for any chain to stop swinging in from its bind pose. It is ignored on a clip that does not loop.`,
				settle, BAKE_MOST_SETTLE);
			return PHYSICS_REFUSED~;
		}
	}

	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string("this document has no dots, so there is no rig to simulate anything on. get_scene reports what is loaded.");
		return PHYSICS_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);

	// The clip before the physics, deliberately: a name that misses is the
	// caller's own typo and the sentence for it is exact, where "nothing on this
	// rig is dynamic" would send them off to fix the document instead.
	AnimRef ref = resolve_named(app, wanted, detail)!;
	AnimTemplate* source = app.clip(ref);

	// Read before the swap, while the source is still where this found it: landing
	// the baked clip may move what `source` points at, and a clip baked over
	// itself is a name this has to be able to still print.
	String source_name = source.name;

	JiggleChainSpec[] chains;
	JiggleColliderSpec[] colliders;
	jiggle_specs_from_document(mem, &app.doc, &view.skeleton, view.dot_ids, &chains, &colliders);
	defer free_jiggle_specs(mem, chains, colliders);

	if (chains.len == 0)
	{
		append_no_dynamic_bones(detail, app);
		return PHYSICS_REFUSED~;
	}

	// The resolver only ever hands back runs it walked out of this very skeleton,
	// so a refusal here is not a shape the document can produce — but it is the
	// difference between a sentence and a crash if one ever is. Dressed the way
	// the viewport's sim is — the skin as the surface, the radii measured — so
	// the bake collides with what was watched.
	JiggleSim? assembled = app.build_dressed_sim(&view, chains, colliders);
	if (catch assembled)
	{
		detail.append_string("the rig's dynamic bones do not describe a chain that can be simulated. A dynamic bone has to hang off a joint above it, and each one after the first has to be the previous one's child.");
		return PHYSICS_REFUSED~;
	}
	JiggleSim sim = assembled;
	defer sim.free(mem);
	defer app.release_jiggle_surface();

	AnimTemplate? made = bake_physics_clip(
		mem, *source, &view.skeleton, view.names, &sim, label, (float)hz, (usz)settle, &app.doc, view.dot_ids);
	if (catch made)
	{
		detail.appendf(
			`"%s" has no keyframes or no length, so there is no stretch of time to simulate over. apply_clip writes one with both.`,
			source_name);
		return PHYSICS_REFUSED~;
	}
	AnimTemplate baked = made;

	bool replaced;
	// author_clip, not put_authored_clip: a baked clip binds into the timeline and
	// becomes the editing clip, so it is selectable, scrubbable and pausable like
	// any authored clip rather than a play-only entry in the pack.
	//
	// One tool call, one undo step — the rule apply_clip follows, and the reason a
	// bake that went wrong is one Ctrl+Z rather than a clip to delete. author_clip
	// commits the clip swap and its binding together.
	AnimRef landed = app.author_clip(baked, &replaced);
	app.refresh_ui();

	return baked_json(app, landed, replaced, source_name, &view, chains, colliders, hz, (usz)settle);
}

<*
 Why a rig with nothing dynamic on it cannot be baked, and what to do first.

 Written here rather than inline because every physics tool needs it: the state
 is the ordinary one — no rig has a dynamic bone until somebody says so — and a
 caller who has not met the feature has no way to guess that the setting lives on
 the rig rather than on the clip.
*>
fn void append_no_dynamic_bones(DString* out, AppState* app)
{
	out.append_string(`no secondary motion on this rig, so a bake would only copy the clip. Physics is a property of the rig rather than of a clip — a chain is given secondary motion once and then swings under every clip that plays — so it has to be set on the rig before there is anything to record. set_secondary_motion is the call that adds one: {"chains":[{"root":"tail_1"}]} hands the run below tail_1 to the solver, and get_skeleton reports which chains are already there.`);

	if (app != null && app.doc.colliders.len() > 0)
	{
		out.appendf(" %d collider capsules are set, but a capsule is only something for a dynamic chain to hit.", app.doc.colliders.len());
	}
}

<*
 What bake_physics answers with: where the clip landed, how densely it was
 sampled, and which bones the answer is actually about.

 `samples_hz` is the rate that was used rather than the one that was asked for —
 the grid is snapped to the solver's substep, so a caller that asked for 50 needs
 to be told it got 48 before it wonders why its keys are where they are.
*>
fn String baked_json(
	AppState* app,
	AnimRef ref,
	bool replaced,
	String source_name,
	RigView* view,
	JiggleChainSpec[] chains,
	JiggleColliderSpec[] colliders,
	double hz,
	usz settle)
{
	AnimTemplate* clip = app.clip(ref);
	AnimPack* pack = app.pack((usz)ref.pack);

	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"clip":"`);
	json_escape_into(&out, clip.name);
	out.append_string(`","pack":"`);
	json_escape_into(&out, pack ? pack.name : "");
	out.append_string(`","source":"`);
	json_escape_into(&out, source_name);
	out.appendf(`","ref":[%d,%d],"replaced":`, ref.pack, ref.clip);
	out.append_string(replaced ? "true" : "false");
	out.appendf(`,"duration":%s,"loop":`, (JsonFloat)clip.duration);
	out.append_string(clip.loop ? "true" : "false");
	out.appendf(`,"keyframes":%d,"samples_hz":%s,"settle_loops":%d,"chains":%d,"colliders":%d`,
		clip.keyframes.len, (JsonFloat)(double)bake_sample_rate((float)hz), settle, chains.len, colliders.len);

	out.append_string(`,"dynamic_joints":[`);
	usz written = 0;
	foreach (chain : chains)
	{
		foreach (joint : chain.joints)
		{
			if (joint >= view.dot_ids.len) continue;
			if (written > 0) out.append_char(',');
			out.append_char('"');
			append_bone_name(&out, view.dot_ids[joint], view.names[joint]);
			out.append_char('"');
			written++;
		}
	}
	out.append_string(`]}`);

	return out.copy_str(mem);
}

// ---------------------------------------------------------------------------
// set_secondary_motion

<*
 How much of a bone's own rest length a capsule with no radius given is swept
 by. A quarter reads as a limb-shaped sleeve on every rig proportioned like a
 figure, and it is derived from the rig rather than picked in model units so it
 is the same sleeve on a mouse and on an elephant.

 Not file-local: the physics panel ticks a capsule on with the same default,
 and a panel that started one thickness where an agent started another would be
 two answers to one question.
*>
const float PHYSICS_COLLIDER_SHARE = 0.25f;

const String SET_SECONDARY_MOTION_SCHEMA = `{"type":"object","properties":{
	"chains":{"type":"array","description":"Chains to give secondary motion, or to retune. A chain is keyed by its root: an entry naming a root that already has one changes that chain, keeping every value the entry leaves out; naming a new root adds one, starting from its preset.","items":{"type":"object","properties":{
		"root":{"type":"string","description":"The dot the chain hangs from, by the name get_skeleton reports; bone_<id> reaches an unnamed one. Its position stays the animation's and its rotation is simulated. The skeleton's own root cannot start a chain — there is nothing above it to hinge from."},
		"tip":{"type":"string","description":"The last dot the chain owns, below the root on one line of bones. Left out on a new chain, the run below the root is followed through every joint with exactly one child and stops at the first fork or at the end — so a tail or a braid needs only its root. At a fork, name the branch you mean."},
		"preset":{"type":"string","enum":["hair","tail","ear","soft"],"description":"Where the values start: hair (loose, collides), tail (the default: firmer, collides), ear (stiff, half gravity, free of the body) or soft (a soft accessory, free of the body). A preset only initializes values — any given alongside it win — and a chain being retuned keeps its values unless a preset is named again."},
		"flexibility":{"type":"number","description":"0 to 1. How far the chain lags behind the pose the clip keys: 0 follows it exactly, 1 hangs off it like a rope. Logarithmic underneath, so 0.5 is a soft, heavy follow. Tail starts at 0.4, hair at 0.55."},
		"damping":{"type":"number","description":"0 to 1. How much of its speed the chain sheds each second: 0 rings for ever, 1 is a dead stop. Tail starts at 0.7, which lets a swing settle in under a second."},
		"gravity":{"type":"number","description":"Multiplier on standard gravity, 9.8 model units per second squared. 1 is earth, 0 a chain that only chases the animation, negative a balloon; anything from -10 to 10 is taken. Ear starts at 0.5, the rest at 1."},
		"collide":{"type":"boolean","description":"Whether the chain is pushed out of the character: its deformed skin, with the chain's own triangles left out, held off by the chain's own thickness as measured from its skin weights, plus any collider capsules the rig carries. Hair and tail start on, ear and soft off. Where the chain may swing is its joints' rotation limits (edit_rig's limits op), not a value here."}
	},"required":["root"]}},
	"colliders":{"type":"array","description":"Extra capsules the chains are pushed out of, on top of the character's own skin: for a rig with no mesh bound, or for a KHR runtime, which is where they are written. A capsule is a bone rather than a free-standing shape, so it follows the animation for nothing.","items":{"type":"object","properties":{
		"joint":{"type":"string","description":"Whose bone the capsule is: the segment from this dot's joint to its tail, which is the direction get_skeleton reports as bone."},
		"radius":{"type":"number","description":"How fat the capsule is, in model units. Omitted, it is a quarter of that bone's own rest length, which is a limb-shaped sleeve to start from. Use clear_colliders to remove one; a radius of 0 is refused rather than read as removal."}
	},"required":["joint"]}},
	"clear":{"type":"array","items":{"type":"string"},"description":"Roots of chains to take back, so their bones go back to being the animation's outright. A dot that roots no chain is quietly left alone."},
	"clear_colliders":{"type":"array","items":{"type":"string"},"description":"Joint names to take the capsule off. A joint that had none is quietly left alone."}
}}`;

<*
 Say which chains of the rig's bones move on their own, or stop them doing it.

 	`String answer = set_secondary_motion_json(app, args, &detail)!;`

 **One call is one undo group, and it is all-or-nothing** — `edit_rig`'s rule,
 followed here for the same reason. A caller who does not like the result must
 take back the call rather than the last chain of it; and a call that is refused
 half-way through would leave a rig neither the caller nor the person at the
 screen described. So the ops are applied through the recorded setters with the
 history cursor remembered, and a refusal walks it back before saying why.

 What is refused is what `AppState.secondary_problem` refuses — a root with
 nothing above it, a tip not below its root, a run crossing another chain, a
 value out of range — plus a preset nobody here knows, since a preset is the
 one field a typo in would silently land as something else.

 @param detail : `Filled with what was refused and what would have been taken instead.`
 @return? PHYSICS_REFUSED : `Nothing was changed. The reason is in detail.`
*>
fn String? set_secondary_motion_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `set_secondary_motion takes an object: {"chains": [{"root": name, "tip": name, "preset": "tail", "flexibility": 0..1, "damping": 0..1, "gravity": 1, "collide": true}], "colliders": [{"joint": name, "radius": …}], "clear": [root name], "clear_colliders": [name]}`)) return PHYSICS_REFUSED~;

	Object* chains;
	Object* capsules;
	Object* clearing;
	Object* clearing_capsules;
	if (!physics_list(args, "chains", &chains, detail)) return PHYSICS_REFUSED~;
	if (!physics_list(args, "colliders", &capsules, detail)) return PHYSICS_REFUSED~;
	if (!physics_list(args, "clear", &clearing, detail)) return PHYSICS_REFUSED~;
	if (!physics_list(args, "clear_colliders", &clearing_capsules, detail)) return PHYSICS_REFUSED~;

	sz asked = physics_len(chains) + physics_len(capsules)
		+ physics_len(clearing) + physics_len(clearing_capsules);
	if (asked == 0)
	{
		detail.append_string(`set_secondary_motion was given nothing to do. It takes "chains" and "colliders" to set and "clear" and "clear_colliders" to take back; a call carrying none of them would answer with the rig exactly as get_skeleton already reports it.`);
		return PHYSICS_REFUSED~;
	}

	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string("this document has no dots, so there is no bone to give secondary motion. apply_plan fits a body plan's rig onto the loaded mesh, and edit_rig places one by hand.");
		return PHYSICS_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);

	Vec3[] tails = view.skeleton.tails(mem);
	defer alloc::free(mem, tails);

	DString set_chains = dstring::new(mem);
	defer set_chains.free();
	DString set_capsules = dstring::new(mem);
	defer set_capsules.free();
	DString cleared = dstring::new(mem);
	defer cleared.free();
	DString cleared_capsules = dstring::new(mem);
	defer cleared_capsules.free();

	// The cursor before anything is applied, the way `edit_rig` takes it: a refusal
	// walks back to here rather than undoing entry by entry, so a rollback that
	// itself gives up part-way cannot leave the rig half-described.
	sz mark = app.undo_stack.cursor;

	// The clears first, so a call that moves a chain — clear the old root, set the
	// new one over the same bones — is one call rather than two. Only what really
	// stopped is reported: a root with no chain answers false, and listing it as
	// cleared would be an answer describing work nobody did.
	for (sz i = 0; i < physics_len(clearing); i++)
	{
		uint id = physics_named(app, clearing, i, "clear", detail);
		if (id == 0)
		{
			physics_rollback(app, mark);
			return PHYSICS_REFUSED~;
		}
		if (app.clear_secondary_recorded(id)) physics_name_row(&cleared, app, id);
	}

	for (sz i = 0; i < physics_len(chains); i++)
	{
		if (physics_chain(app, &view, chains.get_at(i), (usz)i, &set_chains, detail)) continue;
		physics_rollback(app, mark);
		return PHYSICS_REFUSED~;
	}

	for (sz i = 0; i < physics_len(capsules); i++)
	{
		if (physics_capsule(app, &view, tails, capsules.get_at(i), (usz)i, &set_capsules, detail)) continue;
		physics_rollback(app, mark);
		return PHYSICS_REFUSED~;
	}

	for (sz i = 0; i < physics_len(clearing_capsules); i++)
	{
		uint id = physics_named(app, clearing_capsules, i, "clear_colliders", detail);
		if (id == 0)
		{
			physics_rollback(app, mark);
			return PHYSICS_REFUSED~;
		}
		if (app.set_collider_recorded(id, 0.0f)) physics_name_row(&cleared_capsules, app, id);
	}

	app.undo_stack.commit();
	app.refresh_ui();
	return physics_answer(app, &view, &set_chains, &set_capsules, &cleared, &cleared_capsules);
}

// One entry of "chains", validated and applied but not committed.
//
// @return `False when the entry was refused, in which case detail names its index and what was wrong.`
fn bool physics_chain(
	AppState* app,
	RigView* view,
	Object* entry,
	usz index,
	DString* out,
	DString* detail) @local
{
	if (entry == null || !entry.is_keyable())
	{
		detail.appendf(`chains[%d] must be an object with a "root" in it — {"root": name, "flexibility": …} — rather than a bare name.`, index);
		return false;
	}

	uint root = physics_field_dot(app, entry, "root", "chains", index, detail);
	if (root == 0) return false;

	sz root_joint = view.joint_of(root);
	if (root_joint < 0)
	{
		detail.appendf(`chains[%d].root names a dot this rig's skeleton does not hold, which get_skeleton would not report either.`, index);
		return false;
	}
	if (view.skeleton.parents[root_joint] < 0)
	{
		physics_root_refusal(view, (usz)root_joint, index, detail);
		return false;
	}

	// A chain already on this root is retuned from where it stands; a new one
	// starts from its preset — Tail unless the entry says otherwise.
	SecondaryChain chain = app.doc.secondary_of(root);
	bool fresh = !chain.present();
	if (fresh) chain = (SecondaryChain){ .root = root, .tip = app.infer_secondary_tip(view, root) }.with_preset(TAIL);

	if (member(entry, "preset") != null)
	{
		String? label = entry.get_string("preset");
		if (catch label)
		{
			detail.appendf(`chains[%d].preset must be one of "hair", "tail", "ear" or "soft".`, index);
			return false;
		}
		bool known;
		SecondaryPreset preset = secondary_preset_named(label, &known);
		if (!known || preset == CUSTOM)
		{
			detail.appendf(`chains[%d].preset is "%s". It has to be "hair", "tail", "ear" or "soft" — a preset is where the values start, and every one of them can then be stated alongside it.`, index, label);
			return false;
		}
		chain = chain.with_preset(preset);
	}

	if (member(entry, "tip") != null)
	{
		uint tip = physics_field_dot(app, entry, "tip", "chains", index, detail);
		if (tip == 0) return false;
		chain.tip = tip;
	}

	double flexibility = (double)chain.flexibility;
	double damping = (double)chain.damping;
	double gravity = (double)chain.gravity;
	if (!physics_number(entry, "flexibility", index, &flexibility, detail)) return false;
	if (!physics_number(entry, "damping", index, &damping, detail)) return false;
	if (!physics_number(entry, "gravity", index, &gravity, detail)) return false;
	if (member(entry, "swing") != null || member(entry, "thickness") != null)
	{
		detail.appendf(`chains[%d] names swing or thickness, and neither is a chain's any more. Where a chain may turn is its joints' rotation limits — edit_rig's "limits" op, on the bones the chain runs through — and how thick it is is measured off its own skin.`, index);
		return false;
	}

	if (flexibility < 0.0 || flexibility > 1.0)
	{
		detail.appendf(`chains[%d].flexibility is %.9g. It runs from 0 — a chain that follows the clip exactly — to 1, a rope. Tail starts at 0.4.`, index, flexibility);
		return false;
	}
	if (damping < 0.0 || damping > 1.0)
	{
		detail.appendf(`chains[%d].damping is %.9g. It is the share of its speed the chain sheds each second, so it runs from 0 — rings for ever — to 1, a dead stop. Tail starts at 0.7.`, index, damping);
		return false;
	}
	if (math::abs(gravity) > (double)SECONDARY_GRAVITY_LIMIT)
	{
		detail.appendf(`chains[%d].gravity is %.9g. It multiplies standard gravity rather than replacing it, so 1 is earth, 0 is a chain that only chases the animation and a negative value floats it upward; anything from -%.9g to %.9g is taken. A figure in model units per second squared belongs in the multiplier divided by 9.8.`,
			index, gravity, (double)SECONDARY_GRAVITY_LIMIT, (double)SECONDARY_GRAVITY_LIMIT);
		return false;
	}

	chain.flexibility = (float)flexibility;
	chain.damping = (float)damping;
	chain.gravity = (float)gravity;

	if (member(entry, "collide") != null)
	{
		bool? given = entry.get_bool("collide");
		if (catch given)
		{
			detail.appendf(`chains[%d].collide must be true or false: whether the chain is pushed out of the character.`, index);
			return false;
		}
		chain.collide = given;
	}

	String problem = app.secondary_problem(view, chain);
	if (problem.len > 0)
	{
		detail.appendf(`chains[%d]: %s.`, index, problem);
		physics_chain_hint(view, (usz)root_joint, detail);
		return false;
	}

	app.set_secondary_recorded(chain);
	// Reported whether or not the setter changed anything: the caller asked for a
	// state and the state holds, and a chain silently missing from the answer
	// because it already had these values would read as a chain that was skipped.
	physics_chain_row(out, app, view, app.doc.secondary_of(root), fresh);
	return true;
}

// The children a chain rooted here could run down, for a refusal about its
// tip: what the caller almost certainly wants to know next.
fn void physics_chain_hint(RigView* view, usz root, DString* detail) @local
{
	usz joints = view.skeleton.len();
	usz shown = 0;
	for (usz c = 0; c < joints; c++)
	{
		int parent = view.skeleton.parents[c];
		if (parent < 0 || (usz)parent != root) continue;
		detail.append_string(shown == 0 ? ` Below the root: ` : ", ");
		append_bone_label(detail, view.dot_ids[c], view.names[c]);
		shown++;
	}
	if (shown > 0) detail.append_char('.');
}

// One entry of "colliders", validated and applied but not committed.
fn bool physics_capsule(
	AppState* app,
	RigView* view,
	Vec3[] tails,
	Object* entry,
	usz index,
	DString* out,
	DString* detail) @local
{
	if (entry == null || !entry.is_keyable())
	{
		detail.appendf(`colliders[%d] must be an object with a "joint" in it — {"joint": name, "radius": model units} — rather than a bare name.`, index);
		return false;
	}

	uint id = physics_field_dot(app, entry, "joint", "colliders", index, detail);
	if (id == 0) return false;

	sz joint = view.joint_of(id);
	if (joint < 0)
	{
		detail.appendf(`colliders[%d].joint names a dot this rig's skeleton does not hold, which get_skeleton would not report either.`, index);
		return false;
	}

	float bone = (tails[joint] - view.skeleton.joints[joint]).length();
	double fallback = (double)(bone * PHYSICS_COLLIDER_SHARE);
	double radius = fallback;

	Object* given = member(entry, "radius");
	if (given != null)
	{
		// Read loosely, like edit_rig's reach: a radius written as `1` arrives from
		// JSON as an integer and a strict read would refuse a perfectly good number.
		double? want = given.to_value(double, false);
		if (catch want)
		{
			detail.appendf(`colliders[%d].radius must be a number of model units — the same units as get_skeleton's positions.`, index);
			return false;
		}
		if (want <= 0.0)
		{
			detail.appendf(
				`colliders[%d].radius is %.9g. A capsule has to have some thickness to push anything out of: leave the field out and a quarter of that bone's own length is used (%.9g here), and "clear_colliders" is how a capsule is removed.`,
				index, want, fallback);
			return false;
		}
		radius = want;
	}
	else if (fallback <= 0.0)
	{
		DString name = dstring::new(mem);
		defer name.free();
		append_bone_label(&name, view.dot_ids[joint], view.names[joint]);
		detail.appendf(
			`colliders[%d] is "%s", whose bone has no length to measure — the dot sits exactly on its own tail — so there is no quarter of it to take as a default. Give "radius" in model units instead.`,
			index, name.str_view());
		return false;
	}

	app.set_collider_recorded(id, (float)radius);
	physics_capsule_row(out, view.dot_ids[joint], view.names[joint], radius);
	return true;
}

// One optional number off an entry, left at whatever `into` already holds when
// the field is absent. Read loosely, since 0 and 1 arrive from JSON as integers.
fn bool physics_number(Object* entry, String field, usz index, double* into, DString* detail) @local
{
	Object* given = member(entry, field);
	if (given == null) return true;

	double? want = given.to_value(double, false);
	if (catch want)
	{
		// The current value is still in `into` — nothing has been written yet — so
		// the sentence can say what leaving the field out would have been worth.
		detail.appendf(`chains[%d].%s must be a number. Left out it stays at %.9g.`, index, field, *into);
		return false;
	}
	*into = want;
	return true;
}

// A named field that must be an array if it is there at all.
fn bool physics_list(Object* args, String field, Object** into, DString* detail) @local
{
	*into = null;

	Object* found = member(args, field);
	if (found == null) return true;
	if (!found.is_array())
	{
		detail.appendf(`set_secondary_motion's "%s" must be an array. Leave it out entirely to say nothing about it.`, field);
		return false;
	}

	*into = found;
	return true;
}

fn sz physics_len(Object* list) @local => list == null ? 0 : list.get_len();

// The dot a named field of an entry names, or 0 with the refusal written.
// `resolve_dot` has the sentence and the list of alternatives; what a batch adds
// is which entry and field it belongs to.
fn uint physics_field_dot(AppState* app, Object* entry, String key, String field, usz index, DString* detail) @local
{
	String? named = entry.get_string(key);
	if (catch named)
	{
		detail.appendf(
			`%s[%d] needs "%s": a dot, by the name get_skeleton reports; bone_<id> reaches an unnamed one.`,
			field, index, key);
		return 0;
	}
	return physics_resolve(app, named, field, index, detail);
}

// The same, for the two lists that hold bare names rather than objects.
fn uint physics_named(AppState* app, Object* list, sz index, String field, DString* detail) @local
{
	String? named = list.get_string_at(index);
	if (catch named)
	{
		detail.appendf(`%s[%d] must be a dot name, as get_skeleton reports it.`, field, index);
		return 0;
	}
	return physics_resolve(app, named, field, (usz)index, detail);
}

fn uint physics_resolve(AppState* app, String named, String field, usz index, DString* detail) @local
{
	// Into a scratch buffer so the entry's index can go in front of it: the
	// sentence and the alternatives are `resolve_dot`'s, and which entry they
	// belong to is the part a batch needs and a single call does not.
	DString said = dstring::new(mem);
	defer said.free();

	uint? found = resolve_dot(app, named, &said);
	if (catch found)
	{
		detail.appendf("%s[%d]: ", field, index);
		detail.append_string(said.str_view());
		return 0;
	}
	return found;
}

<*
 Why the joint the skeleton hangs from cannot root a chain, and which joints
 below it could have been asked for instead.

 The children by name, because that is what the caller almost certainly meant: a
 chain on the root is what "make the tail wobble" looks like when the tail's
 first dot happens to be the root of a rig with nothing above it.
*>
fn void physics_root_refusal(RigView* view, usz joint, usz index, DString* detail) @local
{
	DString name = dstring::new(mem);
	defer name.free();
	append_bone_label(&name, view.dot_ids[joint], view.names[joint]);

	detail.appendf(
		`chains[%d].root is "%s", which is a root — the skeleton hangs from it and nothing hangs above it. A chain needs both halves of a hinge: an animated point to swing from, which is its parent's, and a position that is the animation's rather than the solver's, which a root already has of its own. There is no parent here to supply either.`,
		index, name.str_view());

	usz shown = 0;
	usz joints = view.skeleton.len();
	for (usz c = 0; c < joints; c++)
	{
		int parent = view.skeleton.parents[c];
		if (parent < 0 || (usz)parent != joint) continue;

		detail.append_string(shown == 0 ? ` Root the chain at the joint below it instead: ` : ", ");
		append_bone_label(detail, view.dot_ids[c], view.names[c]);
		shown++;
	}
	if (shown == 0)
	{
		detail.append_string(" Nothing hangs below it either, so this dot is alone in the rig; connect it to the skeleton with edit_rig before asking it to swing.");
		return;
	}
	detail.append_string(` — the run below that one comes along by itself.`);
}

// The batch taken back to where it started, so a refusal leaves the rig exactly
// as it found it. Committed first: the group is still open, and `undo` walks a
// chain back from a closed edit.
fn void physics_rollback(AppState* app, sz mark)
{
	app.undo_stack.commit();
	while (app.undo_stack.cursor > mark && app.undo()) {}
	// `undo` marks the rig stale, which covers the sim — but a batch that was
	// refused before it recorded anything never reaches that, and the setters it
	// did reach have already reset. Said again here so the invariant does not
	// depend on which of the two happened.
	app.jiggle_reset();
	app.refresh_ui();
}

<*
 One chain as the answer and get_skeleton both print it: root, tip, the joints
 the run resolves to, and every value with the preset resolved — so a readback
 can be handed straight back to this same tool.
*>
fn void physics_chain_row(DString* out, AppState* app, RigView* view, SecondaryChain chain, bool added) @local
{
	if (out.len() > 0) out.append_char(',');
	append_secondary_json(out, app, view, chain);
	// The closing brace is the appender's; whether this call added or retuned the
	// chain is the one thing get_skeleton has no reason to say.
	out.chop(out.len() - 1);
	out.appendf(`,"added":%s}`, added ? "true" : "false");
}

<*
 A chain as JSON, the shape shared by set_secondary_motion's answer and
 get_skeleton's per-dot readback.

 Six figures, the width `get_skeleton` reports everything in: a float widened
 to a double prints nine as 0.300000012, and an answer a caller cannot hand
 straight back to the tool is an answer that has to be cleaned up first.
*>
fn void append_secondary_json(DString* out, AppState* app, RigView* view, SecondaryChain chain)
{
	Dot* root = app.doc.find(chain.root);
	Dot* tip = app.doc.find(chain.tip);

	out.append_string(`{"root":"`);
	append_bone_name(out, chain.root, root ? root.name : "");
	out.append_string(`","tip":"`);
	append_bone_name(out, chain.tip, tip ? tip.name : "");
	out.append_string(`","joints":[`);

	usz[] run = alloc::new_array(mem, usz, (sz)view.len());
	defer alloc::free(mem, run);
	usz length = app.secondary_run_of(view, chain, run);
	for (usz i = 0; i < length; i++)
	{
		if (i > 0) out.append_char(',');
		out.append_char('"');
		append_bone_name(out, view.dot_ids[run[i]], view.names[run[i]]);
		out.append_char('"');
	}

	out.appendf(`],"preset":"%s","flexibility":%.6g,"damping":%.6g,"gravity":%.6g,"collide":%s}`,
		chain.preset.label(), (double)chain.flexibility, (double)chain.damping,
		(double)chain.gravity, chain.collide ? "true" : "false");
}

fn void physics_capsule_row(DString* out, uint dot, String name, double radius) @local
{
	if (out.len() > 0) out.append_char(',');
	out.append_string(`{"joint":"`);
	append_bone_name(out, dot, name);
	out.appendf(`","radius":%.6g}`, radius);
}

fn void physics_name_row(DString* out, AppState* app, uint id) @local
{
	if (out.len() > 0) out.append_char(',');
	out.append_char('"');
	Dot* dot = app.doc.find(id);
	append_bone_name(out, id, dot ? dot.name : "");
	out.append_char('"');
}

<*
 What set_secondary_motion answers with: what this call wrote, and what the
 rig now adds up to.

 The two halves are both needed and neither implies the other. The rows are the
 call's own work with every default resolved, which is the only place a caller
 finds out what "flexibility omitted" turned into. The counts are the *result* —
 read back through `jiggle_specs_from_document`, the same resolver the viewport
 and the bake use — so a caller can tell one tail of four bones from four
 one-bone chains without a second call, and a chain the resolver dropped never
 appears in `dynamic_bones` however loudly this call set it.
*>
fn String physics_answer(
	AppState* app,
	RigView* view,
	DString* chains_set,
	DString* capsules,
	DString* cleared,
	DString* cleared_capsules) @local
{
	JiggleChainSpec[] chains;
	JiggleColliderSpec[] colliders;
	jiggle_specs_from_document(mem, &app.doc, &view.skeleton, view.dot_ids, &chains, &colliders);
	defer free_jiggle_specs(mem, chains, colliders);

	usz dynamic = 0;
	foreach (chain : chains) dynamic += chain.joints.len;

	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"chains":[`);
	out.append_string(chains_set.str_view());
	out.append_string(`],"colliders":[`);
	out.append_string(capsules.str_view());
	out.append_string(`],"cleared":[`);
	out.append_string(cleared.str_view());
	out.append_string(`],"cleared_colliders":[`);
	out.append_string(cleared_capsules.str_view());
	out.appendf(`],"dynamic_bones":%d,"chain_count":%d,"capsules":%d}`, dynamic, chains.len, colliders.len);

	return out.copy_str(mem);
}
