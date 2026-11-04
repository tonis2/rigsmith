<*
 An animation pack: one .glb holding a body plan and everything that plays on it.

 A pack is the unit the library is grouped by. One file carries the clips, the
 rest skeleton they were authored against, a dummy body to show them on, and —
 in the file's root `extras` — what the pack is called and what it is for.

 	`AnimPack pack = crig::read_pack(mem, "assets/animations/biped.glb")!;`
 	`defer pack.free(mem);`

 **The metadata is the file's own `extras`**, which is glTF's slot for whatever
 the authoring tool wanted to say about the asset as a whole:

 	`"extras": { "name": "Biped", "plan": "biped", "tags": "biped, swimming" }`

 Every value is a string, because that is all a glTF reader keeps of them, so
 the tag list is one comma-separated string rather than an array. `plan` is the
 tag a rig has to declare to be offered these clips; `tags` says what the clips
 are *about*, and nothing in the interface reads it yet. They are kept apart
 even though the plan is usually also a tag, because they answer different
 questions: a pack with no plan is still describable, and `swimming` must never
 look like a body plan.

 **A file with no extras at all is still a pack**, just an untagged one — which
 is what every .glb written before packs existed is, and what a plain export out
 of a DCC tool is. It carries its clips and is matched the older way, on a name
 in common with the rig.

 **A file on a rig crig recognises is read onto that rig's body plan.** Nothing
 downloaded carries crig metadata, and a downloaded walk names its joints
 `armature:LeftUpLeg` where the biped plan says `thigh_L` — so the clips would
 arrive intact and match nothing. `core/joint_alias.c3` carries the names across,
 and a pack that said no plan of its own adopts the scheme's. The scheme is
 settled once for the whole file, so the skeleton and every clip in it are named
 the same way or none of them is.

 **No skin is read.** crig binds any mesh to any skeleton itself, so a pack does
 not have to agree with anyone about joint indices or inverse binds; a `skins`
 entry is used only for what it says about which nodes are bones.
*>
module crig;

import rig;
import gltf;
import std::io;
import std::io::path;
import std::sort;
import std::math::vector;
import std::math;
import std::collections::list;
import std::collections::object;
import std::encoding::json;
import std::core::string;



<*
 Raised when a file carries neither a convertible clip nor a named joint. There
 is nothing in it a pack could be made of.
*>
faultdef PACK_EMPTY;

const float PACK_SPARSE_TIME_EPSILON = 1.0e-5f;

const AnimRef NO_ANIM = { -1, -1 };

// The format this reader speaks. A file declaring a higher one is read for its
// clips and nothing else — see `read_pack`.
const uint PACK_VERSION = 1;

// The root `extras` keys. Here rather than spelled at each use, so the reader
// and the writer cannot disagree about them.
const String PACK_KEY_NAME = "name";
const String PACK_KEY_PLAN = "plan";
const String PACK_KEY_TAGS = "tags";
const String PACK_KEY_VERSION = "version";

<*
 "as-is" says the file's skeleton already stands in the frame of the rig it was
 made for, and must not be turned to face +Z (`faces_back`). What a clip
 generated for one character carries (llm-runner's `unimate` plugin writes it):
 it is on the character's own joints, in its own space, however it faces, so
 any turn crig applied would be one the character does not have — and under its
 own joint names, which `read_pack` keeps rather than matching the skeleton onto
 a body plan.
*>
const String PACK_KEY_FACING = "facing";
const String PACK_FACING_AS_IS = "as-is";

<*
 Whether the file is marked as written on the rig it was made for
 (`PACK_KEY_FACING` "as-is"), and so read as it stands: not turned, and not
 matched onto a body plan by shape, since its joints are already named as that
 rig names them.
*>
fn bool as_written(gltf::GltfStream* stream)
{
	if (try String facing = stream.gltf.extras.get(PACK_KEY_FACING)) return facing == PACK_FACING_AS_IS;
	return false;
}

<*
 Which of this pack's joints are optional in the plan it declares — the fingers,
 on the biped.

 Named here rather than inferred, and that is the point of the key existing. A
 plan reaching the matcher is rebuilt out of a pack's rest skeleton by
 `AnimPack.preset`, which sees positions, parents and names; working out that
 `index_2_L` is a finger and `elbow_L` is not would mean reading those names,
 and reading names is the one thing `algo/match/joint_match.c3` is built never to do.
 So the pack's author says so, in the file.

 A pack that does not carry it has no optional joints, which is every pack
 written before this existed and every plan that stops at the wrist.
*>
const String PACK_KEY_OPTIONAL = "optional";

<*
 Per-clip settings glTF has nowhere of its own to put: how a clip blends between
 its keyframes, and which of its joints touch the ground when.

 One key holding a JSON object of clip name to settings, rather than a key per
 clip, because a clip name may contain anything a person can type and a composite
 key would collide. A string holding JSON rather than a nested object because
 `extras` comes back as a string map — the same reason the tag list is one
 comma-separated string; see the note at the top of this file.

 A file that does not carry it is a linear, ungrounded pack, which is every pack
 written before this existed.
*>
const String PACK_KEY_CLIPS = "clips";

<*
 Whose skin weights the file carries. "automatic" says crig wrote its own
 binder's answer — weights derived from the joints, not painted by anyone — so a
 reader rebuilds them from the rig rather than adopting them as authored. Absent
 means somebody else's, or not known, and they are adopted as they are.

 What keeps a model crig saved from turning its own weights into "the file's"
 the next time it opens without its sidecar, and then holding them fixed while
 the joints move away from them — a finger's vertices left behind on the finger
 next to it.
*>
const String PACK_KEY_WEIGHTS = "weights";
const String PACK_WEIGHTS_AUTOMATIC = "automatic";

// Supplemental authoring intent for KHR constraint frames. The actual limits
// remain real `KHR_physics_rigid_bodies` joints; this string only preserves
// which child defined a fork and whether the artist adjusted that derived frame.
const String PACK_KEY_CONSTRAINT_FRAMES = "constraintFrames";

<*
 Read one .glb as a pack.

 One open stream for the whole file: the buffers are loaded once and the clips,
 the skeleton and the mesh all come out of the same bytes.

 Nothing here is fatal except an empty file. A clip that will not convert is
 skipped, a missing skeleton leaves the pack as loose clips, a missing mesh
 leaves it unable to be a body plan, and a version from the future is read for
 its clips alone — refusing it outright would throw away animations that are
 still perfectly good animations.

 The pack owns everything it points at, the metadata strings included: they are
 read out of a structure the stream frees on close.

 @param report : `Filled in with what was found and what was left behind, if given.`
 @param plans : `Body plans this file's rig may be matched onto by shape; empty keeps its own joint names.`
 @param bytes : `The file's bytes, read instead of the file at path, which then only names it. Borrowed, and must outlive the pack when defer_clips is set.`
 @param keep_root_travel : `Leave each clip's root where it carried it, rather than taking its travel off.`
 @return? PACK_EMPTY : `The file carries neither a convertible clip nor a named joint.`
*>
fn AnimPack? read_pack(
	Allocator allocator,
	String path,
	AnimPackReport* report = null,
	Preset[] plans = {},
	bool defer_clips = false,
	char[] bytes = {},
	bool keep_root_travel = false)
{
	gltf::GltfStream stream = bytes.len > 0
		? gltf::open_bytes(bytes, path, allocator)!
		: gltf::open(path, allocator)!;
	// Kept open and handed to the pack when the clips were deferred, so retargeting
	// one later reuses the parse; closed here on every other path.
	bool keep_stream = false;
	defer if (!keep_stream) stream.close();

	// Once, up front. `load_buffer` refcounts and returns early on a slot it has
	// already got, so the per-clip loads below cost a counter each and the mesh
	// read shares the same bytes.
	stream.load_all_buffers()!;

	AnimPackReport tally = {};

	// One body plan for the whole file, settled before anything is read. Matching
	// per clip would let a file whose animations move different parts of the rig
	// come back with its clips named on two different plans and its skeleton on a
	// third; deciding once and handing one plan down means every name in the pack
	// was carried the same way, or none of them was.
	//
	// Not for a file written on the rig it plays on (`PACK_KEY_FACING` "as-is"):
	// its joints already carry that rig's own names, and matching it by shape would
	// rename them onto a plan the rig may not use — a dog read as a biped, its
	// hips and thighs then addressed as joints the dog does not have.
	int which = as_written(&stream) ? -1 : match_stream(allocator, &stream, plans);
	Preset[] matched = which >= 0 ? plans[(usz)which : 1] : (Preset[]){};
	AnimImportOptions naming = { .plans = matched, .keep_source_names = which < 0, .keep_root_travel = keep_root_travel };
	if (which >= 0) tally.plan_matched = plans[(usz)which].name;

	// --- metadata -----------------------------------------------------------

	AnimPack pack = {
		.path = path.copy(allocator),
		.version = PACK_VERSION,
		.owned = true,
		// Remembered for the on-demand import of a deferred clip, so it names joints
		// with the same plan the stubs were read under.
		.plan_match = which,
	};

	if (try String declared = stream.gltf.extras.get(PACK_KEY_VERSION))
	{
		uint? spoken = declared.to_uint();
		if (try spoken) pack.version = spoken;
	}
	tally.too_new = pack.version > PACK_VERSION;

	if (!tally.too_new)
	{
		if (try String plan = stream.gltf.extras.get(PACK_KEY_PLAN))
		{
			pack.plan = trimmed_lower(allocator, plan);
		}
		if (try String tags = stream.gltf.extras.get(PACK_KEY_TAGS))
		{
			pack.tags = split_tags(allocator, tags);
		}
		if (try String name = stream.gltf.extras.get(PACK_KEY_NAME))
		{
			pack.name = name.trim().copy(allocator);
		}
	}
	// A file from an outside tool carries no crig metadata, but a rig shaped like
	// a body plan belongs to that plan as plainly as a tag would say: the clips
	// are about to be named in that plan's words, so matching them to anything
	// else would be matching them to names they no longer carry. Only when the
	// file itself said nothing — an explicit plan is the author speaking, and it
	// wins over a measurement of what the skeleton looks like.
	if (!tally.too_new && pack.plan.len == 0 && which >= 0 && plans[(usz)which].plan.len > 0)
	{
		pack.plan = trimmed_lower(allocator, plans[(usz)which].plan);
		tally.plan_inferred = true;
	}

	tally.tagged = pack.plan.len > 0;
	if (pack.name.len == 0) pack.name = stem_of(allocator, path);

	// --- clips --------------------------------------------------------------

	AnimTemplateList clips;
	clips.init(allocator);

	usz found = gltf_animation_count(&stream);
	tally.clips_found = found;
	for (usz i = 0; i < found; i++)
	{
		if (defer_clips)
		{
			// A stub: the name and length the browser and the timeline need, and the
			// source index to read the curves from later. The retarget — the costly
			// part — waits until the clip is actually sampled, so binding one clip
			// from an 8 MB file no longer pays to convert all of its siblings. See
			// `AppState.ensure_clip_imported`.
			gltf::Animation anim = stream.gltf.animations[(sz)i];
			clips.push({
				.name = clip_label(allocator, &stream, anim, i),
				.duration = anim.duration(),
				.loop = true,
				.owned = true,
				.lazy = true,
				.source = (int)i,
			});
			continue;
		}
		naming.index = (int)i;
		AnimTemplate? one = import_animation(allocator, &stream, naming);
		if (catch one) continue;
		clips.push(one);
	}
	pack.clips = clips.to_array(allocator);
	clips.free();
	tally.clips_read = pack.clips.len;

	if (!tally.too_new)
	{
		if (try String settings = stream.gltf.extras.get(PACK_KEY_CLIPS))
		{
			apply_clip_extras(allocator, pack.clips, settings);
		}
	}

	// --- skeleton -----------------------------------------------------------

	String[] names;
	// The source node per joint, which is the only way to tell a bone carrying a
	// rigid body from a prop that happens to have one — see `read_rig_physics`.
	usz[] joint_nodes;
	rig::Skeleton? rest = read_rest_skeleton(allocator, &stream, &names,
		options: naming, joint_nodes: &joint_nodes);
	if (try rest)
	{
		pack.rest = rest;
		pack.joint_names = names;
		tally.joints = names.len;

		// Skipped for a file this reader does not fully speak, on the same terms as
		// the body below: a physics setup read against a skeleton whose semantics
		// may have changed would be authored work landing on the wrong bones.
		if (!tally.too_new)
		{
			pack.physics = read_rig_physics(allocator, &stream, joint_nodes);
			ConstraintReadReport constraints;
			pack.constraints = read_rig_constraints(allocator, &stream, &pack.rest,
				joint_nodes, &constraints);
			tally.constraints_read = constraints.exact;
			tally.constraints_foreign = constraints.foreign;
			tally.constraint_cones = constraints.cones;
			tally.constraint_drives = constraints.drives;
			tally.constraint_graphs = constraints.graphs;
			tally.constraints_skipped = constraints.skipped;
		}
		if (joint_nodes.len > 0) alloc::free(allocator, joint_nodes);

		// After the names, because the key holds names and this is where they
		// exist. A joint the key lists that the skeleton does not hold is dropped
		// rather than refused — an author trimming a plan should not have to trim
		// the list beside it in the same edit.
		if (!tally.too_new)
		{
			if (try String listed = stream.gltf.extras.get(PACK_KEY_OPTIONAL))
			{
				pack.joint_optional = mark_optional(allocator, names, listed);
			}
		}
	}

	if (pack.clips.len == 0 && tally.joints == 0)
	{
		pack.free(allocator);
		if (report) *report = tally;
		return PACK_EMPTY~;
	}

	// --- body ---------------------------------------------------------------

	// Skipped for a file this reader does not fully speak: its clips are still
	// clips, but a skeleton whose semantics may have changed must never be
	// measured against a mesh and turned into dots.
	if (!tally.too_new)
	{
		rig::TriMesh? body = rig::from_gltf(allocator, &stream);
		if (try body) pack.mesh = body;
		// Stood the way the skeleton was: a figure read facing −Z is turned half
		// round (`source_origin`), and its body has to turn with it or a fit
		// would measure the skeleton against a mesh facing the other way.
		if (faces_back(&stream))
		{
			foreach (&p : pack.mesh.positions) *p = { -p.x, p.y, -p.z };
			foreach (&n : pack.mesh.normals) *n = { -n.x, n.y, -n.z };
		}
	}
	tally.mesh_missing = pack.mesh.positions.len == 0;
	tally.vertices = pack.mesh.positions.len;

	// Hand the parsed file to the pack so a deferred clip retargets from it without
	// re-opening; the deferred close above stands down.
	if (defer_clips)
	{
		pack.stream = stream;
		pack.stream_held = true;
		keep_stream = true;
	}

	if (report) *report = tally;
	return pack;
}

<*
 Every pack in a folder, in name order.

 The order is sorted rather than whatever the filesystem lists, because several
 rules downstream read "the first": which pack claims a body-plan tag, what
 `--preset biped` resolves to, which one the library opens on. An order that
 varies by machine makes all of them vary by machine.

 A file that will not open, or one with nothing usable in it, is skipped — one
 bad download must not cost the user the rest of the library.

 The caller owns the array; free it with `free_packs`.

 @param directory : `Scanned one level deep. A missing folder is an empty library, not an error.`
 @param declared_only : `Skip the second pass — read the files that name a plan and leave the rest.`
*>
fn AnimPack[] scan_packs(Allocator allocator, String directory, bool declared_only = false)
{
	AnimPackList found;
	found.init(allocator);

	String[] files = gltf_files_in(allocator, directory);
	defer free_paths(allocator, files);

	// Asked once per file and kept: the answer opens the file, and the second
	// pass needs it again.
	bool[] names_plan = files.len > 0 ? mem::new_array(bool, (sz)files.len) : {};
	defer if (names_plan.len > 0) alloc::free(mem, names_plan);

	// Pass one: the files that say outright which body plan they are for. Their
	// joints are already named in that plan's words, so they need no matching —
	// and they are the only thing anything else can be matched *against*, which
	// is why they have to be read first.
	foreach (usz i, file : files)
	{
		names_plan[i] = declares_plan(allocator, file);
		if (!names_plan[i]) continue;

		AnimPack? pack = read_pack(allocator, file);
		if (catch pack) continue;
		found.push(pack);
	}

	// The second pass and everything that feeds it. A caller that only wants the
	// declared packs wants exactly this skipped: reading a file to find out what
	// shape its skeleton is means loading its buffers, which is the cost the asset
	// index exists to avoid paying for a folder nobody has opened yet.
	if (declared_only)
	{
		AnimPack[] declared = found.to_array(allocator);
		found.free();
		sort::quicksort(declared, &by_name);
		return declared;
	}

	PresetList references;
	references.init(allocator);
	foreach (&pack : found)
	{
		if (pack.is_body_plan()) references.push(pack.preset(allocator));
	}
	Preset[] plans = references.to_array(allocator);
	references.free();
	defer
	{
		foreach (plan : plans) free_preset(allocator, plan);
		if (plans.len > 0) alloc::free(allocator, plans);
	}

	// Pass two: everything else, matched onto one of those plans by the shape of
	// its skeleton. A file that matches nothing keeps its own joint names and is
	// offered on the older rule — a name in common with the rig.
	foreach (usz i, file : files)
	{
		if (names_plan[i]) continue;

		AnimPack? pack = read_pack(allocator, file, plans: plans);
		if (catch pack) continue;
		found.push(pack);
	}

	AnimPack[] library = found.to_array(allocator);
	found.free();

	sort::quicksort(library, &by_name);
	return library;
}

<*
 The packs for files already known to declare a body plan.

 `scan_packs(declared_only: true)` with the probe taken out. That probe is one
 `gltf::open` per file in the folder purely to read one string out of the root
 `extras` — and the asset index has already read that same string out of that
 same object. An open is not the cheap thing the comment on `declares_plan`
 claims: nearly all of it is the standard JSON reader parsing the whole
 document, about seventy milliseconds on a pack of any size. Two hundred files
 is fourteen seconds of it.

 So a caller that has the index in hand names the declaring files outright and
 this reads those. Sorted by name, like `scan_packs`, because several rules
 downstream read "the first".

 A file that will not open is skipped, the same bargain `scan_packs` makes.

 The caller owns the array; free it with `free_packs`.

 @param files : `Paths to read whole. Borrowed; nothing here keeps them.`
*>
fn AnimPack[] read_declared_packs(Allocator allocator, String[] files)
{
	AnimPackList found;
	found.init(allocator);

	foreach (file : files)
	{
		AnimPack? pack = read_pack(allocator, file);
		if (catch pack) continue;
		found.push(pack);
	}

	AnimPack[] declared = found.to_array(allocator);
	found.free();

	sort::quicksort(declared, &by_name);
	return declared;
}

// Whether a file names its own body plan, without reading a byte of its buffers.
//
// One `gltf::open` per file — cheap only against reading the buffers, not cheap
// in absolute terms; see `read_declared_packs` for the caller that avoids it
// entirely by asking the index instead. Still the answer for `scan_packs`, which
// has no index to ask.
fn bool declares_plan(Allocator allocator, String path) @local
{
	gltf::GltfStream? opened = gltf::open(path, allocator);
	if (catch opened) return false;

	gltf::GltfStream stream = opened;
	defer stream.close();

	// A version this reader does not speak is read for its clips alone, and its
	// plan is not honoured — so it is not a reference either.
	if (try String declared = stream.gltf.extras.get(PACK_KEY_VERSION))
	{
		uint? spoken = declared.to_uint();
		if (try spoken && spoken > PACK_VERSION) return false;
	}

	if (try String plan = stream.gltf.extras.get(PACK_KEY_PLAN)) return plan.trim().len > 0;
	return false;
}

// Bytewise: the only requirement is that two runs on one folder agree.
fn int by_name(AnimPack a, AnimPack b) @local => a.name.compare_to(b.name);

<*
 Free a library `scan_packs` returned, and the array holding it.
*>
fn void free_packs(Allocator allocator, AnimPack[] packs)
{
	foreach (&pack : packs) pack.free(allocator);
	if (packs.len > 0) alloc::free(allocator, packs);
}

// ---------------------------------------------------------------------------
// Reading the metadata strings.

<*
 Put the per-clip settings back on the clips they belong to.

 The counterpart to `clip_extras_text`. Everything here is optional and
 everything malformed is skipped rather than raised: a pack whose settings a
 later crig wrote in a shape this one does not recognise still holds clips, and
 a clip that comes back linear plays — which is more than a refused pack does.

 **Joint names are taken as written.** Clips read off a rig that matched a body
 plan have had their joints renamed into that plan's words, and a ground spec
 written against the original names would then miss. It cannot happen in
 practice: only crig writes this key, and a pack crig wrote keeps its own names.
 A foreign file carries no settings to misapply.

 The feet arrays and their names come from `allocator` and are released by
 `AnimTemplate.free`, so a clip that is not `owned` must not be given one.
*>
fn void apply_clip_extras(Allocator allocator, AnimTemplate[] clips, String source) => @pool()
{
	// Parsed into the temp arena: a clip's sparse keys are thousands of small
	// JSON objects, and one pool released at the end is far cheaper than a heap
	// allocation and free for each. Everything kept is copied with `allocator`,
	// which must therefore not be `tmem`.
	Object*? parsed = json::parse(tmem, source);
	if (catch parsed) return;
	if (!parsed.is_keyable()) return;

	foreach (&clip : clips)
	{
		if (!clip.owned) continue;

		Object*? settings = parsed.get(clip.name);
		if (catch settings) continue;
		if (!settings.is_keyable()) continue;

		if (try String blend = settings.get_string("blend"))
		{
			if (blend == "smooth") clip.blend = SMOOTH;
		}
		if (try bool loop = settings.get_bool("loop")) clip.loop = loop;
		// Not for a deferred clip's stub, which has no keys to schedule: expanding
		// a few hundred schedules only to find nothing they fit cost most of a
		// model's open. Its template gets the schedule when it is imported
		// (`ensure_clip_imported`).
		Object* sparse = clip.keyframes.len > 0 ? settings.get("sparse") ?? null : null;
		if (sparse)
		{
			bool valid_sparse = sparse.is_array() && sparse.get_len() > 0;
			// `"dots":"all"` is a key that keys every joint in `keyed`, each on its
			// entry in `keyed_channels`, or on both where there is none — spelled
			// out here so the checks below read one form.
			if (valid_sparse) for (sz k = 0; k < sparse.get_len(); k++)
			{
				Object* scheduled = sparse.get_at(k);
				if (!scheduled.is_keyable()) continue;
				String every = scheduled.get_string("dots") ?? "";
				if (every != "all") continue;
				Object* keyed = settings.get("keyed") ?? null;
				if (!keyed || !keyed.is_array() || keyed.get_len() == 0)
				{
					valid_sparse = false;
					break;
				}
				Object* kinds = settings.get("keyed_channels") ?? null;
				if (kinds && (!kinds.is_array() || kinds.get_len() != keyed.get_len()))
				{
					valid_sparse = false;
					break;
				}
				Object* listed = object::new_array(tmem);
				for (sz n = 0; n < keyed.get_len(); n++)
				{
					Object* dot = object::new_obj(tmem);
					dot.set("joint", keyed.get_at(n).is_string() ? keyed.get_at(n).s : "");
					String kind = "both";
					if (kinds) kind = kinds.get_at(n).is_string() ? kinds.get_at(n).s : "";
					dot.set("channels", kind);
					listed.push(dot);
				}
				scheduled.set("dots", listed);
			}
			float previous_time = -1.0f;
			if (valid_sparse) for (sz k = 0; k < sparse.get_len(); k++)
			{
				Object* scheduled = sparse.get_at(k);
				Object* dots = scheduled.get("dots") ?? null;
				double? scheduled_time = scheduled.get_float("time");
				if (catch scheduled_time)
				{
					valid_sparse = false;
					break;
				}
				float at = (float)scheduled_time;
				if (!math::is_finite(at) || at < 0.0f || at <= previous_time || !dots || !dots.is_array())
				{
					valid_sparse = false;
					break;
				}
				previous_time = at;
				AnimKeyframe* imported = null;
				foreach (&frame : clip.keyframes)
				{
					if (math::abs(frame.time - at) < PACK_SPARSE_TIME_EPSILON)
					{
						imported = frame;
						break;
					}
				}
				if (!imported)
				{
					valid_sparse = false;
					break;
				}
				for (sz d = 0; d < dots.get_len(); d++)
				{
					Object* dot = dots.get_at(d);
					String joint = dot.get_string("joint") ?? "";
					String kind = dot.get_string("channels") ?? "";
					if (joint.len == 0 || (kind != "both" && kind != "rotation" && kind != "translation"))
					{
						valid_sparse = false;
						break;
					}
					for (sz p = 0; p < d; p++) if ((dots.get_at(p).get_string("joint") ?? "") == joint)
					{
						valid_sparse = false;
						break;
					}
					if (!valid_sparse) break;
					AnimInterpolation rotation_interpolation;
					AnimInterpolation translation_interpolation;
					if (try String value = dot.get_string("rotation_interpolation"))
					{
						if (!parse_anim_interpolation(value, &rotation_interpolation)) { valid_sparse = false; break; }
					}
					if (try String value = dot.get_string("translation_interpolation"))
					{
						if (!parse_anim_interpolation(value, &translation_interpolation)) { valid_sparse = false; break; }
					}
					if ((kind == "translation" && rotation_interpolation != INHERIT)
						|| (kind == "rotation" && translation_interpolation != INHERIT))
					{ valid_sparse = false; break; }
					AnimEase ignored_ease;
					if (!read_ease_field(dot, "rotation_ease", &ignored_ease)
						|| !read_ease_field(dot, "translation_ease", &ignored_ease))
					{ valid_sparse = false; break; }
					AnimTangents ignored_tangents;
					if (!read_tangent_field(dot, "rotation_tangents", &ignored_tangents)
						|| !read_tangent_field(dot, "translation_tangents", &ignored_tangents))
					{ valid_sparse = false; break; }
					bool channel_exists = false;
					foreach (keyed : imported.dots)
					{
						if (keyed.joint_name != joint) continue;
						bool wants_rotation = kind == "both" || kind == "rotation";
						bool wants_translation = kind == "both" || kind == "translation";
						channel_exists = (!wants_rotation || keyed.keys_rotation())
							&& (!wants_translation || keyed.keys_translation());
						break;
					}
					if (!channel_exists)
					{
						valid_sparse = false;
						break;
					}
				}
				if (!valid_sparse) break;
			}
			if (valid_sparse)
			{
				foreach (&frame : clip.keyframes)
				{
					Object* schedule = null;
					for (sz k = 0; k < sparse.get_len(); k++)
					{
						Object* candidate = sparse.get_at(k);
						if (math::abs((float)(candidate.get_float("time") ?? -1.0) - frame.time) < PACK_SPARSE_TIME_EPSILON)
						{
							schedule = candidate;
							break;
						}
					}
					AnimDotList kept;
					kept.init(allocator);
					foreach (dot : frame.dots)
					{
						AnimChannels channels;
						AnimInterpolation rotation_interpolation;
						AnimInterpolation translation_interpolation;
						AnimEase rotation_ease;
						AnimEase translation_ease;
						AnimTangents rotation_tangents;
						AnimTangents translation_tangents;
						bool found = false;
						Object* listed = schedule ? (schedule.get("dots") ?? null) : null;
						if (listed && listed.is_array()) for (sz d = 0; d < listed.get_len(); d++)
						{
							Object* wanted = listed.get_at(d);
							if ((wanted.get_string("joint") ?? "") != dot.joint_name) continue;
							String kind = wanted.get_string("channels") ?? "both";
							channels = kind == "rotation" ? ROTATION
								: (kind == "translation" ? TRANSLATION : BOTH);
							if (try String value = wanted.get_string("rotation_interpolation"))
							{
								(void)parse_anim_interpolation(value, &rotation_interpolation);
							}
							if (try String value = wanted.get_string("translation_interpolation"))
							{
								(void)parse_anim_interpolation(value, &translation_interpolation);
							}
							(void)read_ease_field(wanted, "rotation_ease", &rotation_ease);
							(void)read_ease_field(wanted, "translation_ease", &translation_ease);
							(void)read_tangent_field(wanted, "rotation_tangents", &rotation_tangents);
							(void)read_tangent_field(wanted, "translation_tangents", &translation_tangents);
							found = true;
							break;
						}
						if (found)
						{
							dot.channels = channels;
							dot.rotation_interpolation = rotation_interpolation;
							dot.translation_interpolation = translation_interpolation;
							dot.rotation_ease = channels == TRANSLATION ? (AnimEase){} : rotation_ease;
							dot.translation_ease = channels == ROTATION ? (AnimEase){} : translation_ease;
							dot.rotation_tangents = channels == TRANSLATION ? (AnimTangents){} : rotation_tangents;
							dot.translation_tangents = channels == ROTATION ? (AnimTangents){} : translation_tangents;
							kept.push(dot);
						}
						else if (dot.joint_name.len > 0)
						{
							alloc::free(allocator, dot.joint_name.ptr);
						}
					}
					if (frame.dots.len > 0) alloc::free(allocator, frame.dots);
					frame.dots = kept.to_array(allocator);
					kept.free();
				}
				clip.compile_tracks(allocator);
			}
		}

		// Only ever lengthens. The samplers are the clip and their last time is a
		// fact about it; a shorter duration would put keyframes past the end,
		// which `AnimTemplate.pose` has no reading for.
		if (try double length = settings.get_float("duration"))
		{
			if ((float)length > clip.duration) clip.duration = (float)length;
		}

		Object*? ground = settings.get("ground");
		if (catch ground) continue;
		if (!ground.is_keyable()) continue;

		Object*? feet = ground.get("feet");
		if (catch feet) continue;
		if (!feet.is_array() || feet.get_len() == 0) continue;

		AnimFoot[] planted = alloc::new_array(allocator, AnimFoot, feet.get_len());
		usz kept = 0;
		for (sz f = 0; f < feet.get_len(); f++)
		{
			Object* entry = feet.get_at(f);
			if (!entry.is_keyable()) continue;
			String? joint = entry.get_string("joint");
			if (catch joint) continue;
			if (joint.len == 0) continue;

			planted[kept++] = {
				.joint = joint.copy(allocator),
				.down = (float)(entry.get_float("down") ?? 0.0),
				.up = (float)(entry.get_float("up") ?? 1.0),
				.off_floor = entry.get_bool("off_floor") ?? false,
			};
		}
		if (kept == 0)
		{
			alloc::free(allocator, planted);
			continue;
		}

		clip.ground = { .feet = planted[:kept] };
		if (try double floor = ground.get_float("floor"))
		{
			clip.ground.floor = (float)floor;
			clip.ground.floor_set = true;
		}
	}
}

// Tags are compared, never displayed as typed, so they are folded once here
// rather than at every comparison — a pack tagged "Biped" and a rig plan of
// "biped" are the same statement and have to match.
fn String trimmed_lower(Allocator allocator, String text) @private => text.trim().to_lower_copy(allocator);

// One comma-separated string, because a glTF reader keeps only string values
// out of `extras` and there is nowhere to put an array. Empty entries are
// dropped, so trailing commas and "a,,b" cost nothing.
fn String[] split_tags(Allocator allocator, String text) @local
{
	StringList out;
	out.init(allocator);

	usz start = 0;
	for (usz i = 0; i <= text.len; i++)
	{
		if (i < text.len && text[i] != ',') continue;

		String piece = text[start:i - start].trim();
		start = i + 1;
		if (piece.len == 0) continue;

		out.push(trimmed_lower(allocator, piece));
	}

	String[] tags = out.to_array(allocator);
	out.free();
	return tags;
}

// One flag per joint, from the comma-separated joint names `PACK_KEY_OPTIONAL`
// holds. Compared exactly, unlike the tags: a tag is a word a person types and a
// joint name is a key a clip is addressed by, and `Wrist_L` is not `wrist_L`.
//
// Empty when the list names none of this skeleton's joints, so a caller can test
// the length rather than scanning for a set bit.
fn bool[] mark_optional(Allocator allocator, String[] names, String listed) @local
{
	bool[] flags = alloc::new_array(allocator, bool, (sz)names.len);
	usz marked = 0;

	usz start = 0;
	for (usz i = 0; i <= listed.len; i++)
	{
		if (i < listed.len && listed[i] != ',') continue;

		String piece = listed[start:i - start].trim();
		start = i + 1;
		if (piece.len == 0) continue;

		foreach (usz j, name : names)
		{
			if (name != piece || flags[j]) continue;
			flags[j] = true;
			marked++;
			break;
		}
	}

	if (marked > 0) return flags;
	alloc::free(allocator, flags);
	return {};
}

// The file name without its directory or its extension, which is the pack's
// name when the file does not give one. Capitalised, because it is going in
// front of a user and "biped.glb" is not a label.
//
// The copying form of `file_stem`, which returns a view into `path` — this one
// outlives the call, so it owns its bytes and can afford to alter them.
fn String stem_of(Allocator allocator, String path) @private
{
	String out = file_stem(path).copy(allocator);
	if (out.len > 0) out[0] = out[0].to_upper();
	return out;
}

// A key entry's ease as `,"field":[start,end]`, or nothing when it has none —
// so a clip with no easing writes exactly what it wrote before.
fn void append_ease_field(DString* out, String field, AnimEase ease)
{
	if (ease.none()) return;
	out.appendf(`,"%s":[%s,%s]`, field, (JsonFloat)ease.start, (JsonFloat)ease.end)!!;
}

// Read an entry's ease; absent is none. False for a malformed value.
fn bool read_ease_field(Object* dot, String field, AnimEase* out)
{
	*out = {};
	Object*? found = dot.get(field);
	if (catch found) return true;
	Object* value = found;
	if (!value.is_array() || value.get_len() != 2) return false;
	double? start = value.get_float_at(0);
	double? end = value.get_float_at(1);
	if (catch start) return false;
	if (catch end) return false;
	AnimEase read = { (float)start, (float)end };
	if (!math::is_finite(read.start) || !math::is_finite(read.end)) return false;
	*out = read.clamped();
	return true;
}
