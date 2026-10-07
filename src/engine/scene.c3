<*
 The model, drawn by three.

 crig's replacement for the old `render/mesh_pass.c3`. That file owned pipelines,
 buffers and a shader and recorded its own draw inside cui's render pass; this one
 owns nothing and describes. The mesh becomes an asset in three's scene, the
 cameras and pane rects are pushed to the engine every frame, and the pictures
 come back from three's renderer with three's lighting, culling and shadows.

 ## What crig still decides

 Everything above the geometry. The camera is crig's `OrbitCamera` — the viewport
 widget drags it, the axis snap eases it, and it is *pushed* rather than read
 back, so the projection crig's own overlays use and the one three draws with are
 the same numbers rather than two things kept in step. The pane rect is the
 `Viewport` element's, so the model is centred in the pane and shaped by the
 pane's aspect rather than the window's. The model itself stands at the origin —
 nothing in crig moves it since the Play view went.

 ## What is re-uploaded, and when

 Nothing per frame. An asset is built when the document's geometry changes or the
 tint map does, under a key that carries a serial — three dedups by key, so a key
 that did not move would silently keep the old vertices. The old node is removed
 and `unload_unused` gives the buffers back, which waits for the device on
 three's side.

 That makes a tint change cost a whole re-upload rather than one stream, which is
 the right trade only because tinting is debounced: `weights_due` holds the
 recompute until the user stops dragging, so this runs when a stroke ends and not
 while it is happening.

 ## How the pose gets there

 three's own two skinning paths both start from a skeleton it owns: a baked
 table sampled out of a glTF's clips, or a live palette computed from *bone
 nodes* an `instantiate({ skeleton: true })` materialised. crig's rig is neither.
 The skeleton is `RigView`, the weights come from crig's own binder, and the pose
 is whatever the timeline draft or animation player last worked out — none of it is in
 three's node graph, and mirroring it there every frame would be two skeletons
 kept in step for the privilege of having three recompute what crig already has.

 So the palette crosses whole, through a third path built for exactly this:

 - **The influences ride the geometry.** `sync_mesh` fills `GeometryBuilder`'s
 `joints` and `weights` from `AppState.skin` — the same `SkinBinding`
 `write_rigged` exports, so the preview and the file agree by construction
 rather than by two conversions that have to match.
 - **The asset gets a skin.** `Assets.attach_skin` gives the built asset one
 joint per rig joint with identity inverse binds and an identity rest palette,
 which is the whole of what a vertex's `JOINTS_0` needs to index and what makes
 the mesh draw at rest when nothing is playing.
 - **The pose is pushed every frame.** `Scene.set_palette` takes
 `AppState.pose_palette` as it stands — `world * inverse_bind` per joint,
 identity at rest, which is already three's convention — and `write_live_poses`
 copies it into the frame's live buffer. No shader knows crig exists.

 The shape is the same as everything else here: crig decides, three draws. What
 it costs is one `Matrix4f` per joint per frame, against the mesh's vertices
 being re-uploaded to move a limb.
*>
module crig;

import three;
import cui;
import rig;
import std::math;
import std::sort;
import gltf;

<*
 Where the models are, in three's terms. Empty until the first sync.

 File-private: one process, one scene, and a slot per loaded character in it.
*>
three::Scene* stage @local = null;

<*
 The model's nodes: one in Solid and Wireframe, one per material in Textured —
 three draws one texture per mesh, so a model painted with three materials is
 three meshes over the same skin.
*>
const usz MAX_MODEL_DRAWS = 32;

// How many characters can be on screen at once. Past it, the extra ones are
// edited and saved as ever and simply not drawn.
const usz MAX_CAST_DRAWN = 8;

// How much darker a character is drawn while another is being edited.
const float PARKED_SHADE = 0.62f;

// A line model reads against the dark background where the fill's grey would not.
const Color WIRE_COLOR = { 0.78, 0.80, 0.86, 1.0 };

<*
 One character's draws, and what they were built from.

 A slot per loaded character, found by `Character.id` rather than by position:
 removing a character moves the others along the cast, and a slot keyed by
 position would hand one character's nodes to the next.
*>
struct ModelSlot
{
	// The character this slot draws; 0 is a free slot, since ids start at 1.
	uint character;

	three::NodeId[MAX_MODEL_DRAWS] nodes;
	usz count;
	// The shading the nodes on screen were built for, after the fall-backs: a model
	// with nothing to texture it with is built Solid whatever was asked.
	ShadingMode drawn_shading;

	<*
	 The source file's uvs and material runs, read beside the merged mesh for the
	 Textured view, and the textures its materials resolved to. Read on first need
	 rather than on load: a rigger who never asks for textures never pays for the
	 decode.

	 The textures carry one reference each, held here for as long as the surface is
	 — every mesh built with one takes its own on top, so rebuilding the draws
	 never decodes a picture twice.
	*>
	rig::Surface surface;
	uint surface_geometry;
	bool surface_read;
	int[MAX_MODEL_DRAWS] surface_textures;
	float[4][MAX_MODEL_DRAWS] surface_colors;
	int[MAX_MODEL_DRAWS] surface_materials;
	usz surface_groups;
	bool surface_textured;

	<*
	 What the asset on the device was built from, so `sync` can tell when it is
	 behind the document.

	 Three numbers rather than one because they move independently: the geometry is
	 replaced by File > Open and by the body builder, the tints by a paint stroke
	 settling, and the tint *mode* by a keypress that recomputes nothing. Any of the
	 three means the vertices three is holding are not the ones to draw.
	*>
	uint drawn_geometry;
	uint drawn_tints;
	bool drawn_tinted;
	<*
	 Which binding the influence streams were filled from, and whether they were
	 filled at all.

	 A fourth and fifth number rather than a fold into `drawn_geometry`, for that
	 field's own reason: a rebind moves independently of everything else. Painting
	 a weight or dragging a dot leaves the positions alone and `rebind_skin` bumps
	 `skin_generation` — the vertices three holds are still the right ones and the
	 joints riding them are not.

	 The bool is not redundant with the counter. `load_mesh` empties the binding
	 without rebinding — there is no rig yet to bind to — so the generation does not
	 move while the answer to "is there a skin" changes from yes to no.
	*>
	uint drawn_skin;
	bool drawn_skinned;
	ProjectTransform drawn_transform;
	bool transform_placed;
	// Whether it was drawn as the character being edited, which is the only one
	// drawn tinted and in full colour.
	bool drawn_focus;
	<*
	 How many joints the attached skin has, which is what a palette must be as long
	 as for three to take it.

	 `Character.skin_joints` as it was at the last build rather than as it is now:
	 the palette has to match the *asset*, and a rig that grew a joint since is a
	 rebind away from a rebuild that will match it again.
	*>
	uint drawn_joints;
	// False until the first successful build, which is what distinguishes "nothing
	// has been drawn yet" from "generation 0 is what is on screen".
	bool built;
}

ModelSlot[MAX_CAST_DRAWN] slots @local;

<*
 Bumped for every asset built, and the only thing that varies the key.

 three dedups generated geometry by key — two `new three.BoxGeometry(1,1,1)` are
 one asset — so a rebuild under a key that did not move hands back the *previous*
 mesh and uploads nothing. That is the trap the ABI's `build_mesh` names, and
 this is the counter that avoids it.
*>
uint stage_serial @local = 0;

<*
 Whether a `Viewport` pane was on screen when the rect was last worked out.

 False hides the model rather than leaving it drawing into the rect it had. Every
 pane covering it is opaque, so the difference is invisible until it is not: a
 workspace whose areas do not tile the window — a narrow panel beside empty
 background — would show the previous pane's model floating behind the interface
 with nothing to explain it.
*>
bool pane_on_screen @local = false;
// The first viewport's eye and near plane, and how many viewports there are:
// what a future ghost needs to be drawn over the body (see `sync_ghosts`).
Vec3 primary_eye @local;
float primary_near @local = 0.1f;
usz viewport_count @local = 0;

<*
 The document's mesh, camera and pane, into three. Once per host iteration.

 Ordered cheapest-last on purpose: the rebuild is guarded and almost never runs,
 while the camera and the rect are three stores and a walk over the tree and run
 every frame because they have to — a drag that moved the camera and did not push
 it would draw this frame's overlays over last frame's model.
*>
fn void sync_scene(AppState* app)
{
	if (!hosted()) return;

	// Asked for every frame rather than cached: three's active scene is whatever
	// `new three.Scene()` last made, and a script may have replaced it since the
	// last iteration. Cheap — it is a field read.
	three::Scene* active = stage_pass().scene;
	if (active != stage)
	{
		// A different scene is a different node pool, so the handle held is stale
		// rather than merely elsewhere. Dropped rather than moved: `set_parent`
		// refuses across scenes for exactly this reason.
		stage = active;
		foreach (&slot : slots)
		{
			slot.count = 0;
			slot.built = false;
			slot.transform_placed = false;
		}
		floor_node = three::NO_NODE;
		floor_built = false;
	}
	if (stage == null) return;

	// The rect first, because the mesh's visibility depends on whether there is a
	// pane to draw into and `place_model` is what writes it.
	sync_views(app);
	release_departed(app);
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		ModelSlot* s = slot_for(c.id);
		if (!s) continue;
		sync_mesh(app, s, c);
		// After the mesh and not inside it, because it is owed on every frame and
		// the rebuild is owed on almost none — and because the node it pushes at has
		// to exist, which is the one thing `sync_mesh` decides.
		sync_pose(s, c);
	}
	sync_floor(app);
	// Last: a ghost is a copy of the model's own draws, so they have to exist.
	sync_ghosts(app);
}

<*
 The slot drawing the character with this id, claiming a free one the first time.
 Null when every slot is taken, which leaves that character undrawn.
*>
fn ModelSlot* slot_for(uint character) @local
{
	foreach (&slot : slots)
	{
		if (slot.character == character) return slot;
	}
	foreach (&slot : slots)
	{
		if (slot.character != 0) continue;
		*slot = { .character = character };
		return slot;
	}
	return null;
}

// Whether a character with this id is still loaded.
fn bool still_cast(AppState* app, uint character) @local
{
	for (usz i = 0; i < app.character_count(); i++)
	{
		if (app.character(i).id == character) return true;
	}
	return false;
}

<*
 Take the draws of every character that has left the scene off the screen and
 give their buffers back — a removed character, or the one File > Open replaced.
*>
fn void release_departed(AppState* app) @local
{
	bool released;
	foreach (&slot : slots)
	{
		if (slot.character == 0 || still_cast(app, slot.character)) continue;
		drop_slot_nodes(slot);
		drop_surface(slot);
		*slot = {};
		released = true;
	}
	if (released) sweep_assets();
}

// The slot's nodes out of the scene, palettes first — see `sync_mesh`.
fn void drop_slot_nodes(ModelSlot* s) @local
{
	for (usz i = 0; i < s.count; i++)
	{
		stage.clear_palette(s.nodes[i]);
		stage.remove(s.nodes[i]);
	}
	s.count = 0;
	s.transform_placed = false;
	s.built = false;
}

<*
 The slot drawing the character being edited, or null before it is drawn.
*>
fn ModelSlot* focus_slot(AppState* app) @local
{
	foreach (&slot : slots)
	{
		if (slot.character != 0 && slot.character == app.focus.id) return slot;
	}
	return null;
}

<*
 The active animation pose, into three's live palette. Every frame.

 The one thing here that is genuinely per frame and could not be a generation:
 the palette is rebuilt from scratch by `refresh_animation` on every tick of a
 clip, so "has it changed" is a question with no cheaper answer than pushing it.
 It is one `Matrix4f` per joint — tens of matrices, against the tens of thousands
 of vertices they move.

 **The order across the host iteration is what makes a rebind invisible.**
 `refresh_animation` runs in the app tick, before this, and a rig edit mid-clip
 rebinds the skin there; `sync_mesh` above sees the new `skin_generation`,
 rebuilds and re-attaches; and only then is the palette pushed. So the palette and
 the skin it indexes are never one frame apart.

 The length check is not defensive. `skinned()` and the palette are written by two
 different modes, and a palette built for last frame's rig against this frame's
 asset is exactly the case `set_palette` refuses — so putting the mesh back at
 rest is what a disagreement means, rather than a pose read against the wrong
 joint count.
*>
fn void sync_pose(ModelSlot* s, Character* c) @local
{
	if (!s.built || s.count == 0) return;
	// An unskinned upload has no palette to be given one — no skin on the node,
	// no influences on the mesh, nothing to index. The mesh is its own rest pose.
	if (!s.drawn_skinned) return;

	bool posed = c.skinned() && c.pose_palette.len == (usz)s.drawn_joints;
	for (usz i = 0; i < s.count; i++)
	{
		if (posed && stage.set_palette(s.nodes[i], c.pose_palette)) continue;
		// Nothing is playing, or what is playing does not fit this asset. Either
		// way the node goes back to the identity rest palette `attach_skin`
		// uploaded, which draws the vertices where they were built.
		stage.clear_palette(s.nodes[i]);
	}
}

<*
 ## Ghosts: onion skin as see-through copies of the model

 A ghost is the model's own draws again, as more nodes over the *same assets*
 (`add_mesh` on the asset a model node already shows, so no vertex is uploaded),
 each given the pose of a ghost frame through `set_palette` — the same palette
 path the live model takes, only with a clip evaluated at another time. The CPU
 never skins them; `AppState.ghost_poses` supplies the palettes and caches them.

 Look and draw order come from the material and the node colour, with nothing
 changed in three:

 - Both ghost materials are `BLENDING_NORMAL`, which is `ALPHA_STATE`: blended
 after the opaque pass, depth *tested* and never depth *written*. So ghosts do
 not occlude one another, and are hidden where the live body is in front.
 - **Past ghosts** use `create_texture_material` over that state and nothing
 else, so the live body occludes them: they read as behind it.
 - **Future ghosts** use a vertex-only `create_material` whose `displace` slides
 each vertex along its ray from the camera to just in front of the near plane.
 The pixel it lands on is unchanged, its depth is nearer than anything the live
 body wrote, and the depth test passes — so they draw over the body, see-through.
 The eye is a material uniform, sent every frame, and the shader finds it in
 each node's own space from `v.origin`, so the per-ghost spread offset (below)
 does not need a material of its own.
 - The tint is the node colour: warm for past, cool for future, with its alpha
 the Ghosts opacity times the fade by distance from the playhead.

 - **Spread**: a ghost's node sits at the model's transform plus its offset
 (`ghost_offset_of`, in model space, turned by the model's rotation), so an
 in-place clip fans out instead of stacking on one spot.

 Wireframe shading, and a model drawn as more than a few nodes, keep the old
 skeleton ghosts (`GhostCache.meshed` tells the viewport which).
*>
const usz MAX_GHOST_DRAWS = 4;
const usz MAX_GHOST_NODES = (usz)MAX_GHOSTS * MAX_GHOST_DRAWS;
// How far in front of the camera a future ghost's vertices are pulled to, in
// near planes. Far enough that the nearest corner of the frustum is not clipped.
const float GHOST_NEAR_REACH = 4.0f;

// `displace` runs in the node's own space, before its matrix, and a ghost's node
// is the model's transform plus its own spread offset. So the eye arrives in the
// world (`eye.xyz`) with the model's rotation as three columns, and each vertex
// turns it into its own node's space through `v.origin` (the node's world
// position, offset included): rotate^-1 * (eye - origin).
const String GHOST_FRONT_VERTEX = `fn void displace(inout Vertex v)
{
	float3 d = v.uniforms.eye.xyz - v.origin;
	float3 eye = float3(dot(v.uniforms.col_x.xyz, d), dot(v.uniforms.col_y.xyz, d), dot(v.uniforms.col_z.xyz, d));
	float3 to_vertex = v.position - eye;
	float away = max(length(to_vertex), 0.0001);
	v.position = eye + to_vertex * (v.uniforms.eye.w / away);
}`;

three::NodeId[MAX_GHOST_NODES] ghost_nodes @local;
usz ghost_node_count @local = 0;
uint ghost_nodes_serial @local = 0;
// What the nodes' palettes were last written from; a different cache build
// means the poses moved and they are written again.
uint ghost_pushed_builds @local = 0;
bool ghost_pushed @local = false;
ProjectTransform ghost_transform @local;
float ghost_pushed_spread @local = 0;
int ghost_pushed_direction @local = 0;
bool ghost_materials_made @local = false;
bool ghost_front_made @local = false;
bool ghost_nodes_front @local = false;
uint ghost_back_material @local = three::DEFAULT_MATERIAL;
uint ghost_front_material @local = three::DEFAULT_MATERIAL;

fn void drop_ghost_nodes() @local
{
	if (stage != null)
	{
		for (usz i = 0; i < ghost_node_count; i++)
		{
			stage.clear_palette(ghost_nodes[i]);
			stage.remove(ghost_nodes[i]);
		}
	}
	ghost_node_count = 0;
	ghost_pushed = false;
}

// The two materials, made once and kept for the life of the pass.
fn void ensure_ghost_materials(AppState* app) @local
{
	if (ghost_materials_made) return;
	ghost_materials_made = true;
	three::MeshPass* pass = stage_pass();
	uint? behind = pass.create_texture_material(three::NO_TEXTURE, three::SIDE_FRONT, three::BLENDING_NORMAL);
	if (try behind) ghost_back_material = behind;
	ghost_front_material = ghost_back_material;
	@pool()
	{
		three::MaterialUniform[4] uniforms = { { "eye", 4, 1 }, { "col_x", 4, 1 }, { "col_y", 4, 1 }, { "col_z", 4, 1 } };
		uint? ahead = pass.create_material(&stage_renderer().gpu, &stage_renderer().target, "", uniforms[..],
			three::SIDE_FRONT, three::BLENDING_NORMAL, {}, GHOST_FRONT_VERTEX, 0.0f);
		if (try ahead)
		{
			ghost_front_material = ahead;
			ghost_front_made = true;
		}
		else
		{
			app.@notice("Future ghosts will sit behind the body: three would not take their material.");
		}
	};
}

<*
 The ghost nodes, kept in step with `AppState.ghost_poses`. Every frame, cheap:
 the nodes and palettes change only when the cache or the model does; the colours
 and the eye are three stores.
*>
fn void sync_ghosts(AppState* app) @local
{
	app.ghosts.meshed = false;
	// The ghosts are the character being edited's, drawn over its own assets.
	ModelSlot* s = focus_slot(app);
	bool usable = s && s.built && s.drawn_skinned && s.count > 0 && s.count <= MAX_GHOST_DRAWS
		&& s.drawn_shading != ShadingMode.WIREFRAME;
	GhostPose[] ghosts = usable ? app.ghost_poses() : (GhostPose[]){};
	if (ghosts.len == 0)
	{
		// Hidden rather than dropped: playing a clip stops the ghosts and then
		// they are back, and rebuilding sixty nodes for each is waste.
		for (usz i = 0; i < ghost_node_count; i++) stage.set_visible(ghost_nodes[i], false);
		return;
	}

	ensure_ghost_materials(app);
	// The eye is one camera's: with a second viewport the pulled-forward ghosts
	// would be wrong in it, so the future ghosts go back to sitting behind the body.
	bool front = ghost_front_made && viewport_count == 1;
	usz wanted = ghosts.len * s.count;
	// What the spread is made of: a ghost's node is the model's own transform plus
	// its offset, so a change to either places the nodes again.
	float spread_now = app.ghost_spread() <= 0 ? 0.0f : app.ghost_spread() * app.ghost_rig_height();
	int direction_now = app.ghost_direction();
	bool moved = !ghost_pushed || !ghost_transform.same(app.doc.model_transform)
		|| ghost_pushed_spread != spread_now || ghost_pushed_direction != direction_now;
	if (ghost_nodes_serial != stage_serial || ghost_node_count != wanted || ghost_nodes_front != front)
	{
		drop_ghost_nodes();
		ghost_nodes_serial = stage_serial;
		ghost_nodes_front = front;
		moved = true;
		for (usz i = 0; i < ghosts.len; i++)
		{
			for (usz j = 0; j < s.count; j++)
			{
				three::NodeId model = s.nodes[j];
				three::NodeId node = stage.add_mesh(stage.node(model).asset, 0, stage.root, "crig:ghost");
				if (!node.is_set()) { drop_ghost_nodes(); return; }
				stage.set_skin(node, 0);
				stage.set_material(node, ghosts[i].before || !front ? ghost_back_material : ghost_front_material);
				ghost_nodes[ghost_node_count++] = node;
			}
		}
	}

	bool repose = !ghost_pushed || ghost_pushed_builds != app.ghosts.builds || moved;
	bool visible = app.show_mesh && pane_on_screen;
	float strength = app.ghost_strength();
	bool drawn_any;
	for (usz i = 0; i < ghosts.len; i++)
	{
		GhostPose* ghost = &ghosts[i];
		Color tint = ghost.before ? GHOST_PAST_TINT : GHOST_FUTURE_TINT;
		float[4] color = { tint.r, tint.g, tint.b, strength * ghost.fade };
		bool fits = ghost.palette.len == (usz)s.drawn_joints;
		for (usz j = 0; j < s.count; j++)
		{
			three::NodeId node = ghost_nodes[i * s.count + j];
			if (repose)
			{
				if (fits) stage.set_palette(node, ghost.palette);
				if (moved)
				{
					// The offset is in model space, so it turns with the model.
					Vec3 shift = app.doc.model_transform.orientation().rotate_vec3(app.ghost_offset_of(ghost));
					stage.set_position(node, app.doc.model_transform.location + shift);
					stage.set_quaternion(node, app.doc.model_transform.orientation());
				}
			}
			stage.set_color(node, color);
			stage.set_visible(node, visible && fits);
			drawn_any = drawn_any || fits;
		}
	}
	ghost_pushed = true;
	ghost_pushed_builds = app.ghosts.builds;
	ghost_transform = app.doc.model_transform;
	ghost_pushed_spread = spread_now;
	ghost_pushed_direction = direction_now;
	app.ghosts.meshed = visible && drawn_any;

	if (front)
	{
		// Where the camera is in the world, the model's rotation (its columns,
		// which are the rows of the inverse the shader applies) and how far in
		// front of the camera the vertices are pulled.
		Vec3 eye = primary_eye;
		Quaternionf turn = app.doc.model_transform.orientation();
		Vec3 col_x = turn.rotate_vec3({ 1, 0, 0 });
		Vec3 col_y = turn.rotate_vec3({ 0, 1, 0 });
		Vec3 col_z = turn.rotate_vec3({ 0, 0, 1 });
		float reach = math::max(primary_near, 0.0001f) * GHOST_NEAR_REACH;
		three::Material* material = stage_pass().material(ghost_front_material);
		if (material)
		{
			(void)material.set_uniform("eye", (float[]){ eye.x, eye.y, eye.z, reach });
			(void)material.set_uniform("col_x", (float[]){ col_x.x, col_x.y, col_x.z, 0 });
			(void)material.set_uniform("col_y", (float[]){ col_y.x, col_y.y, col_y.z, 0 });
			(void)material.set_uniform("col_z", (float[]){ col_z.x, col_z.y, col_z.z, 0 });
		}
	}
}

<*
 Rebuilds the model's draws when the document has moved past them.

 The whole mesh, every stream, every time — see the header for why a tint
 change costs a re-upload and why that is affordable. What is built depends on
 the shading: one filled mesh in Solid, one per material in Textured, one line
 mesh over every edge in Wireframe.
*>
fn void sync_mesh(AppState* app, ModelSlot* s, Character* c) @local
{
	rig::TriMesh geometry = c.geometry;
	bool focus = c == &app.focus;

	// Only the character being edited shows its weights: the tint is a reading of
	// the edit in hand, and every panel that explains it is about that one.
	bool tinted = focus && app.tint_mode != TintMode.OFF
		&& c.tints.len > 0
		&& c.tints.len == geometry.positions.len;

	// Optional by length here too, and for the renderer's reason: the shader
	// indexes every stream with one vertex id, so a binding that does not cover
	// every vertex is not a partial skin — it is a read past the end of a buffer.
	// A rig with no joints and a binder that packs into something other than four
	// slots are the other two ways there is nothing to hand over; both are
	// "upload it unskinned", which is the picture crig showed before any of this
	// existed.
	bool skinned = c.skin_joints > 0
		&& c.skin.slots == SKIN_INFLUENCES
		&& c.skin.vertices > 0
		&& c.skin.vertices == (usz)geometry.positions.len;

	// Textured falls back to Solid while a tint says what the colours mean — a
	// weight ramp multiplied into a skin texture is neither — and for a model
	// whose file has no surface to read.
	ShadingMode shading = app.config.viewport_shading;
	if (shading == ShadingMode.TEXTURED && (tinted || !surface_for(app, s, c))) shading = ShadingMode.SOLID;

	if (s.built
		&& s.drawn_geometry == c.geometry_generation
		&& s.drawn_tints == c.tint_generation
		&& s.drawn_tinted == tinted
		&& s.drawn_skin == c.skin_generation
		&& s.drawn_skinned == skinned
		&& s.drawn_shading == shading)
	{
		// Up to date. The per-frame writes are still owed: `show_mesh` is a
		// keypress away and touches no generation.
		place_model(app, s, c);
		return;
	}

	s.drawn_geometry = c.geometry_generation;
	s.drawn_tints = c.tint_generation;
	s.drawn_tinted = tinted;
	s.drawn_skin = c.skin_generation;
	s.drawn_skinned = skinned;
	s.drawn_joints = skinned ? c.skin_joints : 0;
	s.drawn_shading = shading;

	// The old ones go first, whatever happens next. A build that fails leaves an
	// empty view rather than the previous document's model under the current
	// document's dots, which is the same choice `service_open` makes about a file
	// that will not load.
	// The ghosts are copies of the focus's draws and hold the same assets; they
	// go first.
	if (focus || s.drawn_focus) drop_ghost_nodes();
	// The palettes go before the nodes, not left to `sweep_palettes`. Nothing
	// breaks either way — a palette is keyed by `NodeId` and a dead one cannot be
	// resolved — but three sweeps at the next frame's write, and a document closed
	// on the last frame of a session would carry the matrices until the scene went.
	drop_slot_nodes(s);

	if (geometry.positions.len == 0 || geometry.indices.len < 3)
	{
		// An emptied document. The buffers of whatever was there go back here
		// rather than being held until something else is opened.
		sweep_assets();
		return;
	}

	switch (shading)
	{
		case ShadingMode.SOLID: build_solid(app, s, c);
		case ShadingMode.TEXTURED: build_textured(app, s, c);
		case ShadingMode.WIREFRAME: build_wire(app, s, c);
	}

	if (s.count > 0)
	{
		s.built = true;
		place_model(app, s, c);
	}

	// After the new ones are in, so the sweep sees the old assets unreferenced and
	// the new ones held. Called the other way round it would free what was just
	// built.
	sweep_assets();
}

<*
 One vertex of the document's mesh into a builder: position, normal, tint and
 influences, each only when the stream exists for every vertex — which is what
 `upload_built` asks of a stream before taking it.
*>
fn void push_vertex(ModelSlot* s, Character* c, three::GeometryBuilder* shape, usz v, bool with_normals) @local
{
	shape.positions.push(c.geometry.positions[v]);
	if (with_normals) shape.normals.push(c.geometry.normals[v]);
	// Unpacked from the RGBA8 the document holds: three's colour stream is four
	// floats, which is what a glTF COLOR_0 is and what three's shader reads, and
	// the unpack stays on this side so the engine never learns crig's packing.
	if (s.drawn_tinted)
	{
		uint packed = c.tints[v];
		shape.colors.push({
			(float)(packed & 0xFF) / 255.0f,
			(float)((packed >> 8) & 0xFF) / 255.0f,
			(float)((packed >> 16) & 0xFF) / 255.0f,
			(float)((packed >> 24) & 0xFF) / 255.0f
		});
	}
	// The influences, straight out of the binding the export would use. Widened on
	// the way — crig stores a joint as a `ushort` because that is what glTF writes
	// and three reads a `uint4` under scalar layout, the same widening
	// `upload_primitive` does to a file's narrow JOINTS_0.
	//
	// Four fixed rather than a loop over `slots`: `SKIN_INFLUENCES` is four, glTF
	// spells influences in groups of four, and three's shader blends exactly four.
	// A binder that ever packs more would fail the `slots` test in `sync_mesh` and
	// arrive here unskinned rather than half-read.
	if (s.drawn_skinned)
	{
		usz base = v * (usz)c.skin.slots;
		shape.joints.push({
			(uint)c.skin.joints[base],
			(uint)c.skin.joints[base + 1],
			(uint)c.skin.joints[base + 2],
			(uint)c.skin.joints[base + 3]
		});
		shape.weights.push({
			c.skin.weights[base],
			c.skin.weights[base + 1],
			c.skin.weights[base + 2],
			c.skin.weights[base + 3]
		});
	}
}

<*
 The whole mesh, filled, in crig's grey or in the tints. Built straight out of
 the document: `GeometryBuilder` is three's own type and crig fills it directly.
*>
fn void build_solid(AppState* app, ModelSlot* s, Character* c) @local
{
	three::GeometryBuilder shape;
	shape.init();
	defer shape.free();

	bool with_normals = c.geometry.has_normals();
	for (usz v = 0; v < c.geometry.positions.len; v++) push_vertex(s, c, &shape, v, with_normals);
	foreach (at : c.geometry.indices) shape.indices.push(at);
	add_draw(app, s, &shape, false);
}

<*
 Every edge of the mesh once, as lines that ride the same skin — so the
 wireframe poses with the model rather than standing at rest behind it.

 three's lines test no depth, so this is Blender's wireframe with X-ray on: the
 back of the body shows through the front, and so do the dots inside it, which
 is the point of the mode in a rigger.
*>
fn void build_wire(AppState* app, ModelSlot* s, Character* c) @local
{
	uint[] indices = c.geometry.indices;
	usz triangles = indices.len / 3;
	ulong[] edges = alloc::new_array(mem, ulong, (sz)triangles * 3);
	defer alloc::free(mem, edges);

	usz count = 0;
	for (usz t = 0; t < triangles; t++)
	{
		for (usz k = 0; k < 3; k++)
		{
			uint a = indices[t * 3 + k];
			uint b = indices[t * 3 + (k + 1) % 3];
			if (a == b) continue;
			edges[count++] = a < b ? ((ulong)a << 32) | b : ((ulong)b << 32) | a;
		}
	}
	// An edge shared by two triangles is drawn once, not twice over itself.
	sort::quicksort(edges[:count]);

	three::GeometryBuilder shape;
	shape.init();
	defer shape.free();

	for (usz v = 0; v < c.geometry.positions.len; v++) push_vertex(s, c, &shape, v, false);
	for (usz i = 0; i < count; i++)
	{
		if (i > 0 && edges[i] == edges[i - 1]) continue;
		shape.indices.push((uint)(edges[i] >> 32));
		shape.indices.push((uint)(edges[i] & 0xFFFF_FFFF));
	}
	add_draw(app, s, &shape, true);
}

<*
 One mesh per material the source file paints the model with, each holding
 only the vertices its triangles use, with the file's uvs and the material's
 base-colour picture and factor.
*>
fn void build_textured(AppState* app, ModelSlot* s, Character* c) @local
{
	usz vertices = c.geometry.positions.len;
	int[] remap = alloc::new_array(mem, int, (sz)vertices);
	defer alloc::free(mem, remap);
	bool with_normals = c.geometry.has_normals();

	for (usz g = 0; g < s.surface_groups; g++)
	{
		foreach (&slot : remap) *slot = -1;

		three::GeometryBuilder shape;
		shape.init();
		defer shape.free();

		foreach (run : s.surface.runs)
		{
			if (surface_group_of(s, run.material) != g) continue;
			for (usz i = run.index_start; i < run.index_start + run.index_count; i++)
			{
				uint v = c.geometry.indices[i];
				if (remap[v] < 0)
				{
					remap[v] = (int)shape.positions.len();
					push_vertex(s, c, &shape, v, with_normals);
					shape.uvs.push(s.surface.uvs[v]);
				}
				shape.indices.push((uint)remap[v]);
			}
		}
		if (shape.indices.len() < 3) continue;
		add_draw(app, s, &shape, false, s.surface_textures[g], s.surface_colors[g]);
	}
}

<*
 Uploads one shape as a mesh of the model: skins it, places it as a node and
 gives it its picture. Nothing is added when three will not take it.

 @param texture : `A surface texture index, or -1 for none.`
*>
fn void add_draw(AppState* app, ModelSlot* s, three::GeometryBuilder* shape, bool lines, int texture = -1,
	float[4] base_color = { 1.0f, 1.0f, 1.0f, 1.0f }) @local
{
	if (s.count >= MAX_MODEL_DRAWS) return;

	// Bumped for every asset: three dedups by key, so a rebuild under a key that
	// did not move would hand back the previous mesh.
	stage_serial++;
	String key = string::tformat("crig:mesh:%d", stage_serial);

	three::AssetId? made = stage_pass().assets.upload_built(&stage_renderer().gpu, key, key, shape, lines);
	if (catch err = made)
	{
		app.@notice("three would not take the mesh — the viewport will be empty");
		return;
	}

	// Before the node, because `set_skin` reads the asset's skin list and a node
	// given a skin that is not there yet is a node with no skin. A failure here is
	// not fatal to the picture: the mesh keeps its influences, nothing indexes
	// them, and the model draws at rest — which is the same answer crig gave
	// before it could pose at all, rather than an empty viewport.
	if (s.drawn_skinned)
	{
		int? attached = stage_pass().assets.attach_skin(&stage_renderer().gpu, made, s.drawn_joints);
		if (catch attached)
		{
			app.@notice("three would not take the skin — the model will stand at rest");
			s.drawn_skinned = false;
			s.drawn_joints = 0;
		}
		else if (attached < 0)
		{
			s.drawn_skinned = false;
			s.drawn_joints = 0;
		}
	}

	// The picture, on the mesh rather than a material: three's shader samples a
	// mesh's own texture when no material names one. The mesh takes a reference
	// of its own, which unloading the asset gives back.
	three::GpuMesh* mesh = stage_pass().assets.mesh(made, 0);
	if (mesh && !lines)
	{
		mesh.base_color = base_color;
		if (texture >= 0)
		{
			stage_pass().assets.retain_texture(texture);
			mesh.texture = texture;
		}
	}

	// Mesh 0: `upload_built` files one mesh per asset, which is what it does for
	// every generated shape.
	three::NodeId node = stage.add_mesh(made, 0, stage.root, "crig:model");
	if (!node.is_set()) return;
	if (lines) stage.set_material(node, three::LINE_MATERIAL);
	// Skin 0: `attach_skin` files one per asset, the way `upload_built` files one
	// mesh. Until this the node is a prop — three decides a *node* is a character
	// on `Node.skin`, and a palette pushed at one without it is refused.
	if (s.drawn_skinned) stage.set_skin(node, 0);
	s.nodes[s.count++] = node;
}

<*
 Which draw a material's triangles go into: its own, or the last one when the
 file has more materials than there are draws.
*>
fn usz surface_group_of(ModelSlot* s, int material) @local
{
	for (usz g = 0; g < s.surface_groups; g++)
	{
		if (s.surface_materials[g] == material) return g;
	}
	return s.surface_groups - 1;
}

<*
 Whether the Textured view has a surface to draw this model with, reading it
 from the source file the first time it is asked for a model.

 Once per geometry: a file with nothing to read is not read again every frame.
 A body built in crig, a mesh swapped under the rig, or a file whose walk no
 longer lines up with the mesh crig holds all answer no, and draw Solid.
*>
fn bool surface_for(AppState* app, ModelSlot* s, Character* c) @local
{
	if (s.surface_read && s.surface_geometry == c.geometry_generation) return s.surface.runs.len > 0;

	drop_surface(s);
	s.surface_read = true;
	s.surface_geometry = c.geometry_generation;
	if (c.source_path.len == 0 || !hosted()) return false;

	gltf::GltfStream? opened = gltf::open(c.source_path, mem);
	if (catch opened) return false;
	gltf::GltfStream stream = opened;
	defer stream.close();
	if (catch stream.load_all_buffers()) return false;
	// A picture that will not load costs its material the picture, not the view.
	(void)stream.load_all_images();

	rig::Surface? read = rig::read_surface(mem, &stream);
	if (catch read) return false;
	s.surface = read;
	if (!s.surface.fits(&c.geometry))
	{
		s.surface.free(mem);
		return false;
	}

	three::AssetImages images;
	images.memo.init(mem);
	images.blocks.init(mem);
	defer images.free();

	foreach (run : s.surface.runs)
	{
		bool known = false;
		for (usz g = 0; g < s.surface_groups; g++) known = known || s.surface_materials[g] == run.material;
		if (known || s.surface_groups >= MAX_MODEL_DRAWS) continue;

		usz g = s.surface_groups++;
		s.surface_materials[g] = run.material;
		s.surface_textures[g] = -1;
		s.surface_colors[g] = { MESH_COLOR.r, MESH_COLOR.g, MESH_COLOR.b, 1.0f };
		if (run.material < 0) continue;

		gltf::Material material = stream.gltf.materials[run.material];
		s.surface_colors[g] = {
			material.baseColorFactor[0],
			material.baseColorFactor[1],
			material.baseColorFactor[2],
			material.baseColorFactor[3],
		};
		if (!s.surface.has_uvs) continue;
		int? texture = stage_pass().assets.load_material_texture(
			&stage_renderer().gpu, &stream, &images, material.baseColorTexture);
		if (try texture) s.surface_textures[g] = texture;
		if (s.surface_textures[g] >= 0) s.surface_textured = true;
	}

	if (!s.surface_textured) app.@notice("%s has no textures — Textured shows its material colours", base_name(c.source_path));
	return true;
}

<*
 Lets go of the surface and the references its textures held. The meshes drawn
 with them keep their own until the sweep unloads them, which is what waits
 for the device before the last one frees a picture.
*>
fn void drop_surface(ModelSlot* s) @local
{
	for (usz g = 0; g < s.surface_groups; g++)
	{
		if (s.surface_textures[g] >= 0 && hosted())
		{
			stage_pass().assets.release_texture(&stage_renderer().gpu, s.surface_textures[g]);
		}
	}
	s.surface_groups = 0;
	s.surface_textured = false;
	s.surface.free(mem);
}

<*
 Gives back the buffers of everything nothing references any more.

 One line with a name because it is called on five paths through `sync_mesh` and
 the ordering matters on each of them — after the new asset is in, so the sweep
 sees the old one unreferenced and the new one held.
*>
fn void sweep_assets() @local
{
	stage_pass().assets.unload_unused(&stage_renderer().gpu);
}

<*
 Whether the model is shown, and what colour it is.

 Every frame, because `show_mesh` is a keypress that changes no generation.

 The model stands at the origin and always has since the Play view went: the
 only thing that ever moved it was a play script driving a character around, and
 a transform pushed every frame to say "identity" is a call with no question
 behind it. It comes back the day something else moves the mesh.

 The colour is the node's, which multiplies the material — so it carries crig's
 grey while nothing is tinted and gets out of the way when something is, because
 a weight ramp seen through a blue-grey filter is not the ramp.
*>
fn void place_model(AppState* app, ModelSlot* s, Character* c) @local
{
	bool moved = !s.transform_placed || !s.drawn_transform.same(c.doc.model_transform);
	s.drawn_transform = c.doc.model_transform;
	s.transform_placed = true;
	bool focus = c == &app.focus;
	s.drawn_focus = focus;

	float[4] color = { MESH_COLOR.r, MESH_COLOR.g, MESH_COLOR.b, 1.0f };
	if (s.drawn_tinted || s.drawn_shading == ShadingMode.TEXTURED)
	{
		color = { 1.0f, 1.0f, 1.0f, 1.0f };
	}
	else if (s.drawn_shading == ShadingMode.WIREFRAME)
	{
		color = { WIRE_COLOR.r, WIRE_COLOR.g, WIRE_COLOR.b, 1.0f };
	}
	// A character waiting while another is edited is drawn a step darker, so the
	// one the dots and the gizmo belong to is the one that reads as lit.
	if (!focus)
	{
		for (usz k = 0; k < 3; k++) color[k] *= PARKED_SHADE;
	}

	for (usz i = 0; i < s.count; i++)
	{
		three::NodeId node = s.nodes[i];
		stage.set_visible(node, app.show_mesh && pane_on_screen && !c.hidden);
		if (moved)
		{
			stage.set_position(node, s.drawn_transform.location);
			stage.set_quaternion(node, s.drawn_transform.orientation());
		}
		stage.set_color(node, color);
	}
}

<*
 crig's orbit camera, into three's.

 Pushed rather than read back, and the direction is the whole point: crig's
 viewport owns the drag, the dolly, the pan and the axis snap, and its overlays
 project with `OrbitCamera.view_projection`. Reading three's instead would put a
 conversion between the two ends of the same picture. The two structs carry the
 same seven numbers with the same conventions — yaw around +Y with zero on +Z,
 pitch above the horizon, a vertical fov, and a pitch limit of 89° on both sides
 — so this is a copy rather than a mapping.

 The aspect is deliberately not sent: it is the pane's, and three works it out
 from the rect below.
*>
fn three::Camera scene_camera(OrbitCamera* from) @local
{
	three::Camera camera = {
		.target = { from.target[0], from.target[1], from.target[2] },
		.distance = from.distance,
		.yaw = from.yaw,
		.pitch = from.pitch,
		.fov = from.fov,
		.near_plane = from.near_plane,
		.far_plane = from.far_plane,
	};
	camera.clamp_angles();
	return camera;
}

<*
 The panes the scene draws into, as fractions of the window.

 The first `Viewport` supplies the primary view; the rest become extra scene
 views, each with its own camera and another pass over the shared draw buckets.

 No viewport at all — every area on a panel tab — leaves the rect where it was
 and takes the model off screen instead, which `pane_on_screen` is for.

 That includes the *first* iteration, and visibly: this runs before the render, so
 the rects read here are the ones cui laid out last frame and on iteration one
 there are none. The model appears on frame two. Invisible in a window, and it is
 the whole difficulty for `--screenshot`, which would grab frame one and get
 nothing — settling frames before a capture is the answer, as it always was.
*>
fn void sync_views(AppState* app) @local
{
	pane_on_screen = false;
	three::MeshPass* pass = stage_pass();
	three::SceneView[] none = { };
	pass.set_extra_views(none);

	Ui* ui = app.ui;
	if (ui == null || ui.size.x < 1.0f || ui.size.y < 1.0f) return;

	usz count = 0;
	ui.@each(Viewport; elem)
	{
		if (elem.size.x >= 1.0f && elem.size.y >= 1.0f) count++;
	};
	viewport_count = count;
	if (count == 0) return;
	pane_on_screen = true;

	@pool()
	{
		three::SceneView[] views = alloc::new_array(tmem, three::SceneView, (sz)count);
		usz at = 0;
		ui.@each(Viewport; elem)
		{
			if (elem.size.x >= 1.0f && elem.size.y >= 1.0f)
			{
				OrbitCamera* camera = elem.widget_as(Viewport).view_camera(elem);
				if (at == 0)
				{
					primary_eye = camera.eye();
					primary_near = camera.near_plane;
				}
				views[at++] = {
					.camera = scene_camera(camera),
					.rect = {
						elem.absolute.x / ui.size.x,
						elem.absolute.y / ui.size.y,
						elem.size.x / ui.size.x,
						elem.size.y / ui.size.y,
					},
				};
			}
		};

		pass.follow = {};
		pass.camera = views[0].camera;
		pass.view_rect = views[0].rect;
		if (views.len > 1) pass.set_extra_views(views[1..]);
	};
}

// ============================================================================
// The floor
// ============================================================================

<*
 The floor the model stands on: a ruled square at the height of its lowest rest
 vertex, so a foot an animation pushes below it disappears into it.

 Triangles rather than three's line grid, and that is the whole reason this is
 not a `GridHelper`: three draws lines with no depth test, so a line grid would
 be drawn over a sunk foot instead of hiding it — the one thing the floor is for.
 A thin quad per line and a fill under them are depth tested like the model.

 One-sided, facing up: orbiting below it culls it, so the model stays in view
 from underneath.

 It stays where the model stood before it was moved: the height and the size
 come from the mesh and the model's turn, not its location, so moving the model
 up lifts it off the floor (a jump) instead of bringing the floor along. Rebuilt
 when the mesh or the turn changes. View › Floor hides it.
*>
three::NodeId floor_node @local = three::NO_NODE;
bool floor_built @local = false;
// What the floor was built under: a hash of every character's mesh, turn and
// footprint on the ground, so any of them changing builds it again.
ulong floor_key @local = 0;
uint floor_serial @local = 0;

// The fill and the lines, before three's lighting.
const float[4] FLOOR_FILL = { 0.09f, 0.095f, 0.11f, 1.0f };
const float[4] FLOOR_LINE = { 0.17f, 0.18f, 0.21f, 1.0f };
// How far the floor reaches past the model each way, in model heights.
const float FLOOR_REACH = 1.5f;
// About this many cells across the model's height, rounded to a 1-2-5 step.
const float FLOOR_CELLS_PER_HEIGHT = 8.0f;
// A line's width, as a share of the cell.
const float FLOOR_LINE_WIDTH = 0.025f;
// Under the lowest vertex by this share of the height, so a sole resting on the
// floor does not flicker against it; the lines sit half that above the fill.
const float FLOOR_SINK = 0.002f;
const usz FLOOR_MAX_CELLS = 64;

fn void sync_floor(AppState* app) @local
{
	bool drawn;
	foreach (&slot : slots) drawn = drawn || (slot.character != 0 && slot.built);
	bool wanted = !app.config.hide_floor && drawn;
	if (wanted)
	{
		ulong key = floor_key_of(app);
		if (!floor_built || floor_key != key) build_floor(app, key);
	}
	if (floor_node.is_set()) stage.set_visible(floor_node, wanted && pane_on_screen);
}

<*
 A 1-2-5 step near `rough`: 0.1, 0.2, 0.5, 1, 2, 5, 10 …
*>
fn float floor_step(float rough) @local
{
	if (rough <= 0.0f) return 1.0f;
	float decade = math::pow(10.0f, math::floor(math::log10(rough)));
	float scaled = rough / decade;
	if (scaled < 1.5f) return decade;
	if (scaled < 3.5f) return 2.0f * decade;
	if (scaled < 7.5f) return 5.0f * decade;
	return 10.0f * decade;
}

fn void floor_quad(three::GeometryBuilder* shape, float x0, float z0, float x1, float z1, float y, float[4] color) @local
{
	uint base = (uint)shape.positions.len();
	Vec3[4] corners = { { x0, y, z0 }, { x0, y, z1 }, { x1, y, z1 }, { x1, y, z0 } };
	foreach (corner : corners)
	{
		shape.positions.push(corner);
		shape.normals.push({ 0.0f, 1.0f, 0.0f });
		shape.colors.push({ color[0], color[1], color[2], color[3] });
	}
	// Wound so the face points up: (b - a) x (c - a) is +Y.
	foreach (at : (uint[6]) { 0, 1, 3, 3, 1, 2 }) shape.indices.push(base + at);
}

<*
 Everything the floor is measured from, folded into one number: each shown
 character's mesh generation, its turn, and where it stands on the ground.
*>
fn ulong floor_key_of(AppState* app) @local
{
	ulong key = 14695981039346656037ul;
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		if (!c.has_mesh() || c.hidden) continue;
		Quaternionf turn = c.doc.model_transform.orientation();
		float[6] parts = { turn.v[0], turn.v[1], turn.v[2], turn.v[3],
			c.doc.model_transform.location.x, c.doc.model_transform.location.z };
		key = (key ^ c.geometry_generation) * 1099511628211ul;
		foreach (part : parts) key = (key ^ bitcast(part, uint)) * 1099511628211ul;
	}
	return key;
}

fn void build_floor(AppState* app, ulong measured) @local
{
	floor_built = true;
	floor_key = measured;
	if (floor_node.is_set())
	{
		stage.remove(floor_node);
		floor_node = three::NO_NODE;
	}

	// Every model turned the way it stands in the world and set where it stands
	// on the ground, but not lifted: moving one up lifts it off the floor rather
	// than carrying the floor along.
	Vec3 low;
	Vec3 high;
	bool any_vertex;
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		if (!c.has_mesh() || c.hidden) continue;
		Quaternionf turn = c.doc.model_transform.orientation();
		Vec3 shift = { c.doc.model_transform.location.x, 0.0f, c.doc.model_transform.location.z };
		foreach (at : c.geometry.positions)
		{
			Vec3 world = turn.rotate_vec3(at) + shift;
			if (!any_vertex)
			{
				low = world;
				high = world;
				any_vertex = true;
				continue;
			}
			low = { math::min(low.x, world.x), math::min(low.y, world.y), math::min(low.z, world.z) };
			high = { math::max(high.x, world.x), math::max(high.y, world.y), math::max(high.z, world.z) };
		}
	}
	if (!any_vertex)
	{
		sweep_assets();
		return;
	}
	Vec3 size = high - low;
	float span = math::max(size.y, math::max(size.x, size.z));
	if (span <= 0.0f)
	{
		sweep_assets();
		return;
	}

	float cell = floor_step(span / FLOOR_CELLS_PER_HEIGHT);
	// Centred on the model, on a line of the world's grid so the rule does not
	// shift with the model's footprint.
	float cx = math::round((low.x + high.x) * 0.5f / cell) * cell;
	float cz = math::round((low.z + high.z) * 0.5f / cell) * cell;
	float reach = span * FLOOR_REACH + math::max(size.x, size.z) * 0.5f;
	usz cells = math::min((usz)math::ceil(reach / cell), FLOOR_MAX_CELLS);
	float half = (float)cells * cell;
	float y = low.y - span * FLOOR_SINK;
	float line_y = y + span * FLOOR_SINK * 0.5f;
	float w = cell * FLOOR_LINE_WIDTH;

	three::GeometryBuilder shape;
	shape.init();
	defer shape.free();

	floor_quad(&shape, cx - half, cz - half, cx + half, cz + half, y, FLOOR_FILL);
	for (usz i = 0; i <= cells * 2; i++)
	{
		float at = -half + (float)i * cell;
		floor_quad(&shape, cx - half, cz + at - w, cx + half, cz + at + w, line_y, FLOOR_LINE);
		floor_quad(&shape, cx + at - w, cz - half, cx + at + w, cz + half, line_y, FLOOR_LINE);
	}

	floor_serial++;
	String key = string::tformat("crig:floor:%d", floor_serial);
	three::AssetId? made = stage_pass().assets.upload_built(&stage_renderer().gpu, key, key, &shape);
	if (catch made)
	{
		sweep_assets();
		return;
	}
	floor_node = stage.add_mesh(made, 0, stage.root, "crig:floor");
	if (floor_node.is_set()) stage.set_color(floor_node, { 1.0f, 1.0f, 1.0f, 1.0f });
	sweep_assets();
}
