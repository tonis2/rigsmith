<*
 build_body: a mesh generated around the rig that is already open.

 The one tool that replaces the model rather than describing it, and the reason
 it exists is licensing as much as convenience. A rigged humanoid is the easiest
 thing in the world to download and the hardest to ship — every one of them
 arrives under a licence that permits using the character and forbids passing it
 on. A body built here out of the rig's own numbers owes nothing to anybody, and
 a pack saved with `"body":"mesh"` afterwards can serve as a body plan, which is
 the one thing the wire could not do until now.

 **The rig survives and the mesh does not.** Everywhere else in crig a new mesh
 means a new document, for the reason `AppState.load_mesh` gives: a dot is a
 position inside a particular body. Here the body is built around the dots, so
 every one of them is inside it by construction and throwing the document away
 would discard the only thing the mesh was shaped to fit. `replace_geometry` is
 the door that says so.

 **What comes out is a diagram unless it is told otherwise.** One thickness for
 every bone reads as a mannequin made of dowels — enough to see which lump of the
 body a bone carries, which is what three of the four shipped packs want. The
 per-joint overrides are what turn it into a figure, and there is no clever rule
 hiding behind them on purpose: thickness follows anatomy, and anatomy is not
 derivable from a skeleton. A caller shapes one by looking at it.
*>
module crig;

import rig;
import std::collections::object;


faultdef BODY_REFUSED;

<*
 How thick a bone is by default, as a fraction of rig height.

 The same 0.04 `dummy_body` falls back to with no radii at all, so asking for a
 body and asking for one with no arguments give the same mesh.
*>
const double BODY_THICKNESS @local = 0.04;

// Wide enough that a wrist does not vanish and a hip does not swallow the rig.
// Both ends are the shape being refused rather than a limit of the generator:
// below the first a bone is a hair, above the second the body is a boulder.
const double BODY_THINNEST @local = 0.001;
const double BODY_THICKEST @local = 0.5;

// Faces around each bone. Eight reads as round at pane size; the cap is where
// the vertex count stops being worth the smoothness on a body nobody exports.
const usz BODY_SIDES @local = 8;
const usz BODY_MOST_SIDES @local = 64;

// How many dot names a refusal lists before it says there are more. Its twin
// lives in clip.c3, which cannot lend it: `@local` is one file.
const usz BODY_NAME_LIMIT @local = 24;

const String BUILD_BODY_SCHEMA = `{"type":"object","properties":{
	"thickness":{"type":"number","description":"How thick every bone is, as a fraction of rig height. Default 0.04, which reads as a mannequin made of dowels."},
	"sides":{"type":"number","description":"Faces around each bone. Default 8, which reads as round at pane size."},
	"joints":{"type":"array","description":"Per-joint shaping, which is what turns a diagram into a figure. A joint left out takes the defaults.","items":{"type":"object","properties":{
		"joint":{"type":"string","description":"A dot name from get_skeleton."},
		"radius":{"type":"number","description":"This bone's thickness instead of the default, as a fraction of rig height."},
		"ball":{"type":"number","description":"A sphere at the joint, as a fraction of rig height. What hides the pinch where two bones meet at an angle, and what separates a body from a diagram. Omit or zero for none."},
		"ball_back":{"type":"number","description":"How far back towards the parent that sphere sits, 0 at the joint and 1 at the parent. For the one case where the mass a bone carries is centred on neither end of it — a skull, which hangs between the jaw and the crown."}
	},"required":["joint"]}}
}}`;

<*
 Build a body around the live rig and put it under the document.

 Refuses rather than guesses in three places, and each refusal is the caller's
 next move: with no rig there is nothing to build around, with pinned shells
 there are attachments that would survive into a mesh they mean nothing in, and
 a named joint that is not on the rig is a spelling that would otherwise be
 dropped in silence.

 @param detail : `Filled with what was refused and what would have been taken instead.`
 @return? BODY_REFUSED : `The reason is in detail.`
*>
fn String? build_body_json(AppState* app, Object* args, DString* detail)
{
	if (args != null && !args.is_keyable())
	{
		detail.append_string(`build_body takes an object: {"thickness": fraction of rig height, "sides": faces per bone, "joints": [{"joint": name, "radius": …, "ball": …}]}`);
		return BODY_REFUSED~;
	}

	// Asked before the rig is opened, because the sentence is about the document
	// rather than about the skeleton it would have built.
	if (app.doc.attachments.len() > 0)
	{
		detail.appendf(
			`%d pieces of the loaded mesh are pinned to dots, and a generated body's pieces are its bones — nothing those pins would still mean. Detach them with edit_rig first; nothing here sweeps them, because losing a pin with no undo behind it is worse than being asked.`,
			app.doc.attachments.len());
		return BODY_REFUSED~;
	}

	// The pins, on the same terms one level finer: a shell id names a piece of
	// the loaded mesh and a vertex index names a point on it, and a generated
	// body has neither — its vertices are a ring per bone in an order this
	// function decides. Carrying them over would silently pin whichever points of
	// the new mesh happened to land on those indices.
	if (app.doc.pins.len() > 0)
	{
		detail.appendf(
			`%d vertices of the loaded mesh are pinned to dots, and a generated body's vertices are built from the bones — nothing those pins would still name. Clear them with pin_weights reset first; nothing here sweeps them, because losing hand-drawn regions with no undo behind it is worse than being asked.`,
			app.doc.pins.len());
		return BODY_REFUSED~;
	}

	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string("there is no rig to build a body around: this document has no dots. apply_plan fits one in a step, and edit_rig places them by hand.");
		return BODY_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);

	double thickness = BODY_THICKNESS;
	if (member(args, "thickness") != null)
	{
		double? given = args.get_float("thickness");
		if (catch given)
		{
			detail.append_string(`"thickness" must be a number: how thick every bone is, as a fraction of rig height`);
			return BODY_REFUSED~;
		}
		thickness = given;
		if (thickness < BODY_THINNEST || thickness > BODY_THICKEST)
		{
			detail.appendf(
				`"thickness" is %.9g. It is a fraction of the rig's height, between %.9g and %.9g — 0.04 is the default and reads as a mannequin made of dowels.`,
				thickness, BODY_THINNEST, BODY_THICKEST);
			return BODY_REFUSED~;
		}
	}

	usz sides = BODY_SIDES;
	if (member(args, "sides") != null)
	{
		double? given = args.get_float("sides");
		if (catch given)
		{
			detail.appendf(`"sides" must be a number: the faces around each bone, 3 to %d`, BODY_MOST_SIDES);
			return BODY_REFUSED~;
		}
		if (given < 3 || given > (double)BODY_MOST_SIDES)
		{
			detail.appendf(
				`"sides" is %.9g. It is a whole number from 3 to %d: the faces around each bone. A prism needs three to enclose anything, and eight already reads as round.`,
				given, BODY_MOST_SIDES);
			return BODY_REFUSED~;
		}
		sides = (usz)given;
	}

	usz joints = view.skeleton.len();
	float[] radii = alloc::new_array(mem, float, (sz)joints);
	float[] balls = alloc::new_array(mem, float, (sz)joints);
	float[] ball_back = alloc::new_array(mem, float, (sz)joints);
	defer
	{
		alloc::free(mem, radii);
		alloc::free(mem, balls);
		alloc::free(mem, ball_back);
	}
	foreach (&radius : radii) *radius = (float)thickness;

	if (!read_shaping(&view, member(args, "joints"), radii, balls, ball_back, detail)) return BODY_REFUSED~;

	rig::TriMesh body = dummy_body(mem, &view.skeleton, radii, sides, balls, ball_back);
	if (body.positions.len == 0)
	{
		body.free(mem);
		detail.append_string("the rig produced no surface: every dot is a root with nothing connected to it, so there are no bones to build around. edit_rig's connect is what makes a chain out of a scatter.");
		return BODY_REFUSED~;
	}

	// Handed over on every path from here, uploaded or not.
	usz vertices = body.positions.len;
	usz triangles = body.triangle_count();
	rig::Bounds box = body.bounds();
	// The upload used to go through a `remesh` hook the executable installed. There
	// is no executable, and the plugin needs no hook: `replace_geometry` bumps
	// `geometry_generation`, and `engine/scene.c3`'s `sync_scene` rebuilds three's
	// asset off that counter on the next frame. So the swap is unconditional and
	// `drawn` is the honest question of whether anything is going to draw it —
	// which is whether a host is attached at all.
	app.replace_geometry(body);
	bool drawn = hosted();

	app.refresh_ui();
	return built_json(app, vertices, triangles, box, drawn);
}

<*
 The `joints` array, folded onto the three arrays `dummy_body` reads.

 @return `False when an entry was refused, with the reason in detail.`
*>
fn bool read_shaping(
	RigView* view,
	Object* shaping,
	float[] radii,
	float[] balls,
	float[] ball_back,
	DString* detail) @local
{
	if (shaping == null) return true;
	if (!shaping.is_array())
	{
		detail.append_string(`"joints" must be an array of {"joint": name, "radius": …, "ball": …, "ball_back": …}`);
		return false;
	}

	for (usz i = 0; i < (usz)shaping.get_len(); i++)
	{
		Object* entry = shaping.get_at((sz)i);
		if (!entry.is_keyable())
		{
			detail.appendf(`joints[%d] must be an object with a "joint"`, i);
			return false;
		}

		String? given = entry.get_string("joint");
		if (catch given)
		{
			detail.appendf(`joints[%d] needs "joint": the dot this entry shapes`, i);
			return false;
		}
		String name = given;

		usz at = radii.len;
		foreach (j, held : view.names)
		{
			if (held == name) at = (usz)j;
		}
		if (at >= radii.len)
		{
			detail.appendf(`joints[%d].joint is "%s", which is not a dot on this rig. It has: `, i, name);
			append_view_names(detail, view);
			return false;
		}

		if (!read_measure(entry, "radius", i, &radii[at], detail)) return false;
		if (!read_measure(entry, "ball", i, &balls[at], detail)) return false;
		if (!read_measure(entry, "ball_back", i, &ball_back[at], detail)) return false;
	}
	return true;
}

// One shaping number, if the entry carries it.
fn bool read_measure(Object* entry, String key, usz index, float* into, DString* detail) @local
{
	if (member(entry, key) == null) return true;
	double? given = entry.get_float(key);
	if (catch given)
	{
		detail.appendf(`joints[%d].%s must be a number`, index, key);
		return false;
	}
	// Refused rather than clamped: all three are a length or a fraction along
	// one, and a caller that wrote a minus sign meant something this cannot do.
	if (given < 0)
	{
		detail.appendf(`joints[%d].%s is %.9g, and none of the three shaping numbers can be negative`, index, key, given);
		return false;
	}
	*into = (float)given;
	return true;
}

fn void append_view_names(DString* out, RigView* view) @local
{
	usz shown = 0;
	foreach (name : view.names)
	{
		if (name.len == 0) continue;
		if (shown == BODY_NAME_LIMIT)
		{
			out.append_string(", and more");
			return;
		}
		if (shown > 0) out.append_string(", ");
		out.append_string(name);
		shown++;
	}
	if (shown == 0) out.append_string("no named dots at all");
}

<*
 What `build_body` answers with.

 The bounds are here because they are the one thing a caller cannot work out
 from the rig it asked to build around: a body is thicker than the skeleton
 inside it, and by how much is what `thickness` decides.
*>
fn String built_json(AppState* app, usz vertices, usz triangles, rig::Bounds box, bool drawn) @local
{
	DString out = dstring::new(mem);
	defer out.free();

	out.appendf(`{"vertices":%d,"triangles":%d,"dots":%d,"bounds":{"min":`, vertices, triangles, app.doc.dots.len());
	append_vec3(&out, box.min);
	out.append_string(`,"max":`);
	append_vec3(&out, box.max);
	out.append_string(`,"size":`);
	append_vec3(&out, box.extent());
	out.append_char('}');

	// Not a failure: a crig with no window has nothing to draw on, which is the
	// state every headless check runs in.
	out.append_string(`,"drawn":`);
	out.append_string(drawn ? "true" : "false");
	out.append_string(`,"note":"the rig is untouched — the body was built around it, so every dot is still inside it. Weights rebind from scratch. This replaced the loaded model and is not undoable."}`);

	return out.copy_str(mem);
}
