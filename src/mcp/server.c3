<*
 The registry, and the reads: get_scene, get_skeleton, get_pose, measure_clip and
 delete_clip, as functions over AppState that take and return JSON strings.

 No sockets and no cui in here — the transport drives the same
 `ToolTable.handle_message` the tests do, and everything below is
 headless-assertable: raw JSON in, raw JSON out. `screenshot` is the one tool that
 needs a window, and reaches it through a hook on the AppState rather than by
 importing a renderer: see `AppState.screenshot` and `screenshot_content`.

 **The whole surface is registered here and most of it is implemented
 elsewhere.** `new_tool_table` is the one list of what Rigsmith can be asked to do,
 and every handler below it is a thin adapter from the wire to a builder — three
 lines, usually, and where a handler is longer than that it is parsing arguments
 rather than doing work. Which file the work is in:

 	clip.c3      apply_clip: parsing, validation and the pack it writes into
 	rig.c3       edit_rig, as one undo step
 	body.c3      build_body
 	physics.c3   set_secondary_motion and bake_physics
 	weights.c3   show_weights, get_weights, paint_weights, pin_weights, fix_strays, get_shells
 	play.c3      play and stop, for the person at the screen
 	pack.c3      save_pack, the one tool that leaves a file behind
 	render.c3    render and set_camera
 	screenshot.c3 the picture, and the window it needs
 	docs.c3      get_api_docs, and the tool reference read off this registry
 	names.c3     clip, pack and dot lookup, and the refusal when a name misses

 What is left in this file, beyond the registry, is the reads that answer straight
 out of the document: the scene, the skeleton, a sampled pose, a clip's metrics.
 They leave the document alone, so they need none of the redraw the writers ask
 for — the socket is pumped between frames, and a loop that sleeps when idle has
 nothing else to tell it the document moved.

 **Most of the tools are `hidden`** — registered, dispatched, tested, and left
 out of `tools/list`. A handful are listed, and `new_tool_table` says which and
 why. Nothing about a handler changes when its flag does; what changes
 is whether a client is told it exists before it is asked for.

 Every builder allocates its result from `mem`; the caller frees it.
*>
module crig;

import rig;
import std::collections::object;
import std::collections::list;

import std::math;

faultdef RIG_EMPTY, POSE_BAD_ARGS;

<*
 apply_clip's argument shape, as the client sees it.

 Held apart from the registration because it is the one schema with any depth
 to it, and because it is the closest thing the wire has to documentation: a
 client shows these descriptions to the model before it writes a call, so what
 is said here is what an agent knows before its first attempt rather than after
 its first rejection.
*>
const String APPLY_CLIP_SCHEMA = `{"type":"object","properties":{
	"name":{"type":"string","description":"Clip name. A clip of this name in the authored pack is replaced."},
	"duration":{"type":"number","description":"Seconds. Defaults to the last keyframe's time; must not be shorter than it."},
	"loop":{"type":"boolean","description":"Whether playback wraps. Default false."},
	"blend":{"type":"string","enum":["linear","smooth"],"description":"How the clip moves between keyframes. linear (default) goes straight between them; smooth fits a cubic through them and, on a looping clip, through the loop point too — so a cycle can be written as the eight poses it passes through rather than as a resampling of them."},
	"ground":{"type":"object","description":"Which joints touch the floor and when. Rigsmith then solves the root's height against the rig actually loaded, so the same clip plants correctly on figures with different leg lengths. While any contact is down the solve sets the root's height outright: an authored root Y, keyed or from a layer, is cancelled then, so stance height comes from how the legs bend. It adds on top only while every foot is off the floor, which is where a flight arc goes. A joint may appear once for each window it is down. Left out, a clip of this name already authored keeps its own spec; null clears it.","properties":{
		"feet":{"type":"array","items":{"type":"object","properties":{
			"joint":{"type":"string","description":"A dot name from get_skeleton."},
			"down":{"type":"number","description":"Cycle phase the foot plants, 0 to 1 — a fraction of the duration, not seconds."},
			"up":{"type":"number","description":"Cycle phase it leaves. At or below down, the window wraps through the loop point, which is what one foot of a gait always does."},
			"off_floor":{"type":"boolean","description":"A contact that is not on the floor, such as a hand on a wall: planted and measured, but the height solve leaves it alone. Default false."}
		},"required":["joint"]}},
		"floor":{"type":"number","description":"Model-space height the feet rest on. Defaults to the lowest contact joint's own rest height, which is where the modeller put the sole."}
	},"required":["feet"]},
	"layers":{"type":"array","description":"The clip's layer stack, each in set_layer's layer shape (kind keyed|wave|noise|pulse, mode additive|override, weight, mask, keyframes, joint/tip, axis, amplitude, cycles, lag, falloff, ...). Stated, it replaces the stack and an empty list clears it; left out, a clip of this name already authored keeps its own. get_crig_docs topic layers.","items":{"type":"object"}},
	"mirror":{"type":"object","description":"Fill in the other side. Every joint whose name ends _L or _R gets its twin driven by the reflected motion, and the ground windows are mirrored with it. Write one leg and one arm; this writes the rest.","properties":{
		"phase":{"type":"number","description":"How much of the cycle the mirrored side lags by, 0 to 1. Default 0.5, which is a walk or a run."}
	}},
	"keyframes":{"type":"array","description":"In increasing time order. Each joint's rotation and move are independent tracks: omission means no key at this time, not rest, and unrelated entries do not interrupt interpolation.","items":{"type":"object","properties":{
		"time":{"type":"number","description":"Seconds from the start of the clip."},
		"joints":{"type":"array","items":{"type":"object","properties":{
			"name":{"type":"string","description":"A dot name from get_skeleton. Unnamed dots cannot be animated."},
			"rotation":{"description":"Quaternion {x,y,z,w}, axis and angle {axis:[x,y,z],angle:radians}, or euler [x,y,z] radians turned about the X, then Y, then Z axes of whichever frame space names. Omit to leave this channel unkeyed at this time."},
			"rotation_interpolation":{"type":"string","enum":["hold","linear","auto"],"description":"How this rotation leaves the key: hold keeps it unchanged until the next rotation key, linear uses SLERP, and auto uses the smooth fitted curve. Omit to inherit the clip blend."},
			"pivot":{"type":"string","description":"Root entry only: the name of a joint the root's rotation turns about instead of the root's own point (a front shoulder, a foot, the head). The root's move is adjusted so that joint stays where it was — where this keyframe's other entries and move put it without the turn. Any other joint's entry refuses a pivot."},
			"space":{"type":"string","enum":["local","world"],"description":"Which frame this entry's rotation and move are measured in. local, the default, is a turn against the parent as this clip has already posed it — so the axis a joint answers to moves as the joints above it move, and is the model's own axis only while nothing above it is turned. world states where the joint points against the model's axes whatever the chain above is doing, and Rigsmith works out the turn that lands there; it is the only workable way to write a rig that rests in a T-pose and animates with its arms down. Mixing them inside one keyframe is fine and often right: the shoulder in world, the elbow as a hinge off it."},
			"move":{"type":"array","description":"[x,y,z] slide as a fraction of rig height, not model units. Omit to leave this channel unkeyed at this time. An entry must provide rotation, move, or both.","items":{"type":"number"}},
			"rotation_ease":{"description":"How the rotation segment leaving this key spends its time: [start, end], each 0 (untouched) to 1 (a flat tangent at that end), or \"in\" (starts slow), \"out\" (settles), \"in_out\". The path is the same; only its pacing changes — a reach that accelerates away and settles into the next pose instead of moving at one rate. Omit for even pacing.","anyOf":[{"type":"array","items":{"type":"number"}},{"type":"string","enum":["in","out","in_out","none"]}]},
			"translation_ease":{"description":"The same for the move segment leaving this key.","anyOf":[{"type":"array","items":{"type":"number"}},{"type":"string","enum":["in","out","in_out","none"]}]},
			"translation_interpolation":{"type":"string","enum":["hold","linear","auto"],"description":"How this move leaves the key: hold keeps it unchanged until the next move key, linear goes straight, and auto uses the smooth fitted curve. Omit to inherit the clip blend."}
		},"required":["name"]}}
	},"required":["time"]}}
},"required":["name","keyframes"]}`;

<*
 The server bound to `app`: every tool and the api-docs resource. The AppState
 must outlive the server — tool handlers hold the pointer, not a copy.

 Registration order is the order `tools/list` reports, and a client shows that
 list to a model in the order it arrives: reads first, then the write, then the
 player, then the picture, then the document that explains all of them.

 **A few of these are listed and the rest are `hidden`.** Every one is registered
 and every one is dispatched — by `tools/call` as before, and by a script's
 `__crig_call`, which walks this same table. What the flag decides is only what a
 client is handed before it asks.

 The reason is what the surface costs when nobody uses it. Twenty-seven
 descriptions and their schemas are about thirty-five thousand characters, and a
 client puts all of it in the model's context at the start of every session and
 keeps it there — whether the session rigs a character or asks where the
 viewport is pointing. Set against that, most of these tools are not decisions at
 all: `edit_rig` places sixty-five dots, `apply_clip` composes a hundred and
 fifty orientations, `paint_weights` is measure-adjust-measure. They are loops,
 and a loop is cheaper written once as JavaScript than emitted call by call.
 three's `run_script` is that door (`plugin_abi.md` §9 — a script reaches this
 whole table as `crig.ops.<name>`); hiding the loops behind it turns a toll paid
 on every request into a lookup paid by the caller that wants it.

 So the few that stay are the ones a session actually opens with, and each earns
 it twice — a single decision rather than a loop, *and* a schema small enough that
 listing it is not the cost being avoided:

 - `get_scene` and `screenshot`: the two orientation calls, no arguments, and the
   first thing anything does. Wrapping either in a script would cost more to write
   than the call saves.
 - `undo` and `redo`: they cannot move behind a script, because a script is
   forbidden from calling them — they step a cursor the calls around them
   recorded against. Hidden, they would be unreachable rather than merely
   unlisted.
 - `get_api_docs`: the conventions, which are what a caller needs *before* it
   writes against any of them.
 - `list_poses`, `get_saved_pose` and `tween_poses`: the person saves poses in
   the Pose tab and asks for an animation between them by name, so the agent
   has to see that these exist without being told.
 - `measure_clip`: the verdict on a clip. An agent that never learns it exists
   ships clips whose knees the rig clamps straight and whose keys snap, judging
   them by contact sheets that fall either side of the fault.
 - `render`, `set_camera`, `get_annotations` and `solve_targets`: looking at the
   work, and the one-call reach a person asks for by pointing.

 Discovery is what this costs, and it is paid for in the prelude: `crig.help()`
 names every tool here and `crig.help(name)` returns this registration's own
 description and schema, so a hidden tool documents itself out of the table
 rather than out of a second copy that drifts.
*>
fn ToolTable new_tool_table(AppState* app)
{
	// The name and version the server used to carry are three's to declare now —
	// it is the one answering `initialize`, and Rigsmith is one plugin inside it.
	ToolTable server;

	server.add_tool({
		.name = "get_scene",
		.description = "Mesh stats, bounds, space and unit conventions, the rig's counts, every animation pack and clip in the library, and the live playback state.",
		.input_schema = `{"type":"object","properties":{}}`,
		.handler = &tool_get_scene,
		.user_data = app,
	});
	server.add_tool({
		.name = "get_skeleton",
		.description = "The rig: dots (id, name, rest position and any bone-local rotation limits), edges, the root, the BFS joint order with parents and bone directions, and the rig height. Bones are addressed by name; unnamed dots answer to bone_<id>. Limit angles are radians; absent limits mean the joint is entirely free.",
		.input_schema = `{"type":"object","properties":{}}`,
		.handler = &tool_get_skeleton,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "get_pose",
		.description = "Sample a clip at time t against the live rig, as it plays and exports: the keys held inside the rig's joint limits, grounded, pinned and aimed. Every joint's world position and world orientation (quaternion [x,y,z,w]), and limited: each joint whose keyed turn the limits changed, with the radians removed — a keyed bend that plays straight shows there. The numeric eyes — author blind, then read this back and adjust.",
		.input_schema = `{"type":"object","properties":{"clip":{"type":"string","description":"Clip name, or \"Pack/Clip\" to say which pack. A bare name two packs share is an error."},"t":{"type":"number","description":"Seconds from the clip's start","default":0}},"required":["clip"]}`,
		.handler = &tool_get_pose,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "measure_clip",
		.description = "Whether a clip is fit to ship, and what to call to make it so. Answers verdict usable or needs_work, clip_verdict (the same with the rig's own faults, marked of_rig, left out: whether this clip's keys are done), an issues list that localizes each fault to a joint, a phase and (for a pop on a key) the key, the rig's faults last, and fixes: one call per kind of fault with its arguments filled in. Measured as the clip plays and exports — the keys held inside the rig's joint limits, grounded, pinned and aimed. Faults (each marked blocks:false is reported without making the verdict needs_work): limits_inverted / limits_blocked (the rig's knee or elbow limits refuse the natural fold — every clip plays clamped until edit_rig plan_limits mends it), limits_stale (a joint's limit table still pinned to where its bone pointed before it moved; its fix carries that one table onto its bone), pop (a joint snapping: a leftover partial key, a limit clamp flipping, a loop whose end jumps to its start — found by walking every key and 120 instants a second, so a snap between frames is still seen), root_pop (the body's height jumping where the floor solve changes feet), foot_slide (a planted foot skating; a clip with no ground spec is measured by the feet its motion plants), floor_penetration, limit_saturation (keys turning a joint past its limits, read before the limits hold them; never blocks, since what plays is the held pose), loop_position / loop_velocity (the seam), and aim_stare (a note: a look-at on one still point). Beside them the aggregates: foot_slide, ground_speed (how fast the figure must travel for an in-place cycle not to skate), floor_penetration, stride, root bob, and every joint's travel and height range, as fractions of rig height. Every tool that writes a clip answers with these numbers under metrics; get_crig_docs topic quality is the loop to follow.",
		.input_schema = `{"type":"object","properties":{"clip":{"type":"string","description":"Clip name, or \"Pack/Clip\" to say which pack. A bare name two packs share is an error."},"samples":{"type":"number","description":"Even instants for the slide, seam and travel measurements. Default: sixty a second of clip, 32 to 256. Pops are always walked at every key and 120 a second."}},"required":["clip"]}`,
		.handler = &tool_measure_clip,
		.user_data = app,
	});
	server.add_tool({
		.name = "get_clip",
		.description = "A clip's stored keyframes, in exactly the shape apply_clip takes — so a clip can be read, changed and written back without reconstructing it from samples. get_pose samples a clip at an instant and measure_clip measures one; this is the keys themselves, including the ones a person keyed by hand in the timeline. Rotations come back as an axis and an angle, which is what the format actually stores. editable says whether apply_clip would change this clip or fork it: only the authored pack is Rigsmith's to write. The ground spec, layers, aims and pins come with it; apply_clip reads the ground and layers back, and keeps a clip's own aims and pins, which set_aim and set_pins change.",
		.input_schema = `{"type":"object","properties":{"clip":{"type":"string","description":"Clip name, or \"Pack/Clip\" to say which pack. A bare name two packs share is an error."}},"required":["clip"]}`,
		.handler = &tool_get_clip,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "apply_clip",
		.description = "Answers with measure_clip's verdict, issues and fixes for what was written, under metrics — a clip is not done until it reads usable (get_crig_docs topic quality). Write an animation clip into the authored pack, replacing any clip of the same name, and bind it into the timeline as the selected, editable clip — so play then pause holds it rather than snapping back to another clip. Joints are addressed by the names get_skeleton reports. Rotation and move are independent sparse tracks: omit either to leave that channel unkeyed at this time, but provide at least one. A rotation is a quaternion, axis and angle, or three euler radians, measured against the parent by default or against the model's axes with space set to world; world conversion samples the complete ancestor tracks at that time. Move is a fraction of rig height. Keyframe times must increase. A keyed channel can set its outgoing interpolation to hold, linear or auto; otherwise it inherits the clip blend. Give the clip a ground spec to plant feet against the loaded rig or a mirror to write the other side. The clip becomes playable in Rigsmith's own library.",
		.input_schema = APPLY_CLIP_SCHEMA,
		.handler = &tool_apply_clip,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "bake_physics",
		.description = "Simulate the rig's secondary-motion chains over a clip and write what they did into the authored pack as ordinary keyframes. Physics otherwise exists only while the player is running — a tail that swings on screen swings in no render, no saved pack and no exported file, because glTF has nowhere to put a solver. The baked clip is a full resample of the source with the secondary motion folded in, so it plays, exports and retargets like any other. Refuses when nothing on the rig is dynamic, which is a property of the rig rather than of the clip.",
		.input_schema = BAKE_PHYSICS_SCHEMA,
		.handler = &tool_bake_physics,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "list_poses",
		.description = "List the saved poses in the project's pose library — the ones the person saved in Rigsmith's Pose tab. They refer to them by name (\"animate from walk-start to walk-end\"); get_scene's saved_poses names them too. Answers names and how many joints each holds.",
		.input_schema = `{"type":"object","properties":{}}`,
		.handler = &tool_list_poses,
		.user_data = app,
	});
	server.add_tool({
		.name = "get_saved_pose",
		.description = "One saved pose's joint values, in the joint shape get_clip and apply_clip use — the reference when the person names a pose as a start, end or key of an animation.",
		.input_schema = `{"type":"object","properties":{"pose":{"type":"string","description":"A name list_poses reports."}},"required":["pose"]}`,
		.handler = &tool_get_saved_pose,
		.user_data = app,
	});
	server.add_tool({
		.name = "save_pose",
		.description = "Save the pose a clip has at an instant into the pose library, under a name — one undo step, and it shows in the Poses panel. Use it to capture a start pose and an end pose, or to keep a good frame. A pose of that name is replaced.",
		.input_schema = SAVE_POSE_SCHEMA,
		.handler = &tool_save_pose,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "delete_pose",
		.description = "Delete a saved pose from the library, as one undo step.",
		.input_schema = `{"type":"object","properties":{"pose":{"type":"string","description":"A name list_poses reports."}},"required":["pose"]}`,
		.handler = &tool_delete_pose,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "tween_poses",
		.description = "Write a clip that goes from one saved pose to another over a duration (or there and back), into the authored pack, bound into the timeline like apply_clip. The starting point for 'here is the start and end pose, animate between them'; refine with patch_clip or apply_clip afterwards.",
		.input_schema = TWEEN_POSES_SCHEMA,
		.handler = &tool_tween_poses,
		.user_data = app,
	});
	server.add_tool({
		.name = "get_annotations",
		.description = "The person's sketches over the viewport (the Sketch tool, the pencil in the viewport's tool column): each mark's ink (red wrong, green keep, blue note), points as fractions of the viewport, the clip and time on screen, the camera it was drawn from, and the joints the stroke passes near. screenshot shows the marks painted over the model. clear deletes them after reading; delete removes one by id.",
		.input_schema = GET_ANNOTATIONS_SCHEMA,
		.handler = &tool_get_annotations,
		.user_data = app,
	});
	server.add_tool({
		.name = "delete_clip",
		.description = "Delete one of the project's own animations for good — what the asset browser's Delete does: it comes off the character, out of the authored pack, and, for a clip saved into the loaded model, out of the model's file, which is re-saved. A library file's clips are refused; unbind_clip takes any clip off the character instead. Ctrl+Z (undo) brings the clip and its binding back.",
		.input_schema = `{"type":"object","properties":{"clip":{"type":"string","description":"The clip's name, or \"Pack/Clip\"."}},"required":["clip"]}`,
		.handler = &tool_delete_clip,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "apply_plan",
		.description = "Fit a body plan's own skeleton onto the loaded mesh: seventeen or so named dots under one undo entry, measured against the model's bounding box. The usual first call on a fresh mesh, and what makes it something a clip can be written for — a clip addresses joints by name, and a mesh with no rig has none.",
		.input_schema = `{"type":"object","properties":{"plan":{"type":"string","description":"A body-plan tag or pack name — biped, quadruped, bird. get_scene lists what the library holds."},"facing":{"type":"string","enum":["auto","front","back"],"description":"Which way round to fit it: auto (the default) measures which way the model faces, from its feet and then from how the plan fits its body; front fits it facing +Z, the Front view, the way crig reads every figure; back facing -Z. The answer's notice says \"facing -Z\" when it went that way."}},"required":["plan"]}`,
		.handler = &tool_apply_plan,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "edit_rig",
		.description = "Change the rig: place, move, name, remove, connect, disconnect dots, move the root, or edit bone-local rotation limits (x and z the swing across the bone, y the twist about it). A list of ops is applied as one undo step, and an op that fails takes the whole call back. Limit angles are radians; each axis is allowed inside its minimum/maximum or held at its locked value. A branch follows the child that carries its bone on unless primary_child names another or a frame is given. Naming matters most: only a named dot can be animated.",
		.input_schema = EDIT_RIG_SCHEMA,
		.handler = &tool_edit_rig,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "set_secondary_motion",
		.description = "Give a chain of bones secondary motion — a tail, an ear, a braid, anything whose motion is what the rest of the body did to it a moment ago — or retune or take back one. A chain is a root dot and a tip dot below it; name only the root and the run below it is followed to its end. Its behaviour is a preset (hair, tail, ear, soft) plus flexibility and damping from 0 to 1, a gravity multiplier and whether it collides with the character — its deformed skin, held off by a thickness measured from the chain's own skin; where it may swing is its joints' rotation limits. Physics is a property of the rig rather than of a clip, so a chain set here swings under everything that plays. Colliders are extra capsules along a bone, for a rig with no mesh or a KHR runtime. One call is one undo step and an entry that fails takes the whole call back. Then play to watch it and bake_physics to make it something a file can hold.",
		.input_schema = SET_SECONDARY_MOTION_SCHEMA,
		.handler = &tool_set_secondary_motion,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "build_body",
		.description = "Generate a body around the rig that is already placed, and load it as the working mesh. The rig survives — the body is built around the dots, so every one of them is still inside it — and the weights rebind from scratch. One thickness for every bone gives a mannequin made of dowels; the per-joint radius and ball are what turn that into a figure, and they are meant to be arrived at by looking at one. This is how a model Rigsmith can ship gets made, and how save_pack's \"body\":\"mesh\" gets something to write. It replaces the loaded model and cannot be undone.",
		.input_schema = BUILD_BODY_SCHEMA,
		.handler = &tool_build_body,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "undo",
		.description = "Step the rig's history back — the same history the viewport writes, so a step may take back an edit made here or one the user made by hand, whichever came last.",
		.input_schema = `{"type":"object","properties":{"steps":{"type":"number","description":"How many edits to take back. Default 1; stops early when the history runs out.","default":1}}}`,
		.handler = &tool_undo,
		.user_data = app,
	});
	server.add_tool({
		.name = "scale_model",
		.description = "Resize the whole model about its origin — the mesh, the joints, their reaches and collider radii — as one undo step, for a model made at the wrong size. Give the height it should stand, or a factor. Clips keep playing the same, since their moves are fractions of rig height. save_project then writes the new vertex positions into the model with the skin.",
		.input_schema = `{"type":"object","properties":{"height":{"type":"number","description":"How tall the model should stand, in model units along Y."},"factor":{"type":"number","description":"How much to grow it by, instead of a height: 2 doubles it."}}}`,
		.handler = &tool_scale_model,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "redo",
		.description = "Step the rig's history forward again. Anything recorded after an undo discards what was undone, which is what makes this worth calling promptly or not at all.",
		.input_schema = `{"type":"object","properties":{"steps":{"type":"number","description":"How many edits to put back. Default 1; stops early when there is nothing left to redo.","default":1}}}`,
		.handler = &tool_redo,
		.user_data = app,
	});
	server.add_tool({
		.name = "play",
		.description = "Play a clip in Rigsmith's own player, which is what the person at the screen sees. Optionally from a given time, optionally looping whether or not the clip does, and optionally without the secondary motion any dynamic bones would add. Playing is for a person to watch; get_pose is how a clip is checked numerically, and neither needs the other.",
		.input_schema = `{"type":"object","properties":{"clip":{"type":"string","description":"Clip name, or \"Pack/Clip\" to say which pack. A bare name two packs share is an error."},"t":{"type":"number","description":"Seconds from the clip's start to begin at. A looping clip wraps a time past its end; a clip that does not loop refuses one.","default":0},"loop":{"type":"boolean","description":"Loop this run whatever the clip says. Changes the playing copy only, never the stored clip."},"sim":{"type":"boolean","description":"Simulate the rig's dynamic bones on top of the clip. On by default; false shows the keyed pose alone, which is how a clip is watched without a tail lagging behind it. A clip with no dynamic bones plays the same either way.","default":true}},"required":["clip"]}`,
		.handler = &tool_play,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "stop",
		.description = "Stop playback and put the mesh back at rest. Stopping when nothing is playing is not an error.",
		.input_schema = `{"type":"object","properties":{}}`,
		.handler = &tool_stop,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "save_pack",
		.description = "Publish every authored clip into Rigsmith's animation library as a pack file. Saving under the name of a pack that already exists adds to it, replacing only clips of the same name. Project-owned authored copies and their bindings remain intact; normal project Save separately persists them in the session sidecar. Rigsmith reads the published file back as a library pack; use Pack/Clip when a name occurs in both copies. Set body to dummy or mesh and the pack becomes a body plan in its own right, which is what a pack needs to be fitted onto a fresh model rather than merely played on one — and a body is enough on its own, so a rig placed with edit_rig on a fresh model is saved as a body plan with no clip authored first. Only a save that would carry neither a clip nor a body is refused. The file always goes in the library folder; the caller names the pack, not the path.",
		.input_schema = `{"type":"object","properties":{
	"name":{"type":"string","description":"The pack's name in the library. The file name is derived from it; anything that is not a letter, digit, dash or underscore becomes an underscore."},
	"plan":{"type":"string","description":"Body-plan tag the pack is written for. Defaults to the tag the target pack already carries, or the one this rig declares. An empty string writes a pack offered to every rig."},
	"body":{"type":"string","enum":["none","dummy","mesh"],"description":"What body the file carries. none, the default, writes a clip file: playable, but it can never be fitted as a body plan, because a plan normalises its joints against the body's own bounding box and there is no box without one. dummy writes a stand-in built around this rig, a few KB. mesh writes the model that is loaded. A pack being saved over keeps no body of its own — the skeleton in the file is the rig loaded now, and an older body was shaped around an older rig."},
	"optional":{"type":"array","items":{"type":"string"},"description":"Dot names a plan fitted from this pack may leave unplaced. Only meaningful on a pack that carries a body, and it is what separates the joints a mesh's proportions actually say the position of from the ones they do not — fingers above all. A joint left off this list is placed on every model the plan is ever fitted to, so a hand's worth of knuckles gets guessed onto figures that have none. Omitted keeps whatever the pack being saved over marked; an empty array marks none."}
},"required":["name"]}`,
		.handler = &tool_save_pack,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "show_weights",
		.description = "Paint the mesh with one of Rigsmith's weight views, for the person at the screen: territory (which dot owns each vertex), falloff (one dot's share of each vertex, grey 0 to orange 1), or off. Showing is for them; get_weights is the same answers as numbers, and neither needs the other.",
		.input_schema = `{"type":"object","properties":{
	"mode":{"type":"string","enum":["off","territory","falloff"],"description":"Which view to paint."},
	"dot":{"type":"string","description":"Dot the falloff view ramps from; selects it, which is what that view reads. Required by falloff when nothing is selected, ignored by the rest."}
},"required":["mode"]}`,
		.handler = &tool_show_weights,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "get_weights",
		.description = "The weight views as numbers: how many vertices each dot owns and how many it reaches, and how much of the mesh no dot is near. Naming a dot adds what it takes from its neighbours — the vertices another dot owns that this one still pulls on, which is where a mesh smears when the rig moves. vertices adds each named vertex's row: the dots holding it, their shares, and whose edit wrote its pins. strays adds every island of a dot's weight cut off from the rest of it and far away — the spike a pose pulls out of the body — with how far a pose can pull it (pull and gap, over the model's height) and the dots holding the mesh around it; fix_strays puts them back. Reads the binder's own weights, so it answers whether or not a view is being shown.",
		.input_schema = `{"type":"object","properties":{"dot":{"type":"string","description":"Dot to survey against its neighbours, by the name get_skeleton reports; bone_<id> works here, since a survey reads the bind rather than a clip. Omit for the ownership table alone."},"vertices":{"type":"array","items":{"type":"number"},"description":"Vertex indices whose rows to add: the dots holding each, strongest first, as the views show them."},"strays":{"type":"boolean","description":"Add the stray islands, farthest from their dot's region first. Default false."}}}`,
		.handler = &tool_get_weights,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "paint_weights",
		.description = "Correct the bind by hand: say what share of some vertices a dot should hold, and Rigsmith writes it as each vertex's row — the same edit the brush makes. The vertices are named the way get_weights names them — 'the ones hip owns that knee still pulls on' is a shared row from that tool with a target on the end — so a smear you can see in the survey is fixed in the same words you read it in. The rest of each row goes to the other dots as they hold it, or, where they hold only a few percent, to the dots the distance field says would own the vertex — never to a sliver. A stated row holds where it was put when a dot moves; for an edit that moves with the rig, edit_rig's grow pushes a joint's region out instead. One call is one undo step. Reset takes every hand edit off.",
		.input_schema = `{"type":"object","properties":{"dot":{"type":"string","description":"Whose share is being set, by the name get_skeleton reports."},"share":{"type":"number","description":"0 to 1: what fraction of each vertex this dot should end up holding. 0 takes it off them entirely; 1 gives it the whole vertex."},"owned_by":{"type":"string","description":"Only vertices this dot owns outright — the 'name' of a shared row from get_weights. Omit for every vertex the bounds match."},"at_least":{"type":"number","description":"Only where the painted dot already holds at least this share. 0.05 is the floor get_weights reports at, so it selects exactly the vertices that tool listed."},"at_most":{"type":"number","description":"Only where it holds at most this share. Default 1."},"vertices":{"type":"array","items":{"type":"number"},"description":"Explicit vertex indices instead of a selection. For a caller that already knows which ones — get_weights reports them, and a script can compute them."},"reset":{"type":"boolean","description":"Take every hand edit off the rig — stated rows and pins alike — and ignore everything else. The way back to the automatic weights."}},"required":["dot"]}`,
		.handler = &tool_paint_weights,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "pin_weights",
		.description = "Hand vertices to a dot outright: a pin states the share, the last word on a vertex. paint_weights writes the same layer — this is the blunt form, which takes the vertices off every other dot's pins unless exclusive is false. It does not track the rig: move the dot and a pin says what it said before; edit_rig's grow is the edit that moves with it. Vertices are selected the way paint_weights selects them. One call is one undo step; reset takes every pin off. The user draws these by hand with the lasso, shift+T.",
		.input_schema = `{"type":"object","properties":{"dot":{"type":"string","description":"Which dot the vertices are handed to, by the name get_skeleton reports."},"share":{"type":"number","description":"0 to 1: what fraction of each vertex this dot ends up holding. 1 is rigid — the vertex is wholly this dot's. 0 removes the pin. Default 1."},"owned_by":{"type":"string","description":"Only vertices this dot owns outright — the 'name' of a shared row from get_weights. Omit for every vertex the bounds match."},"at_least":{"type":"number","description":"Only where the pinned dot already holds at least this share."},"at_most":{"type":"number","description":"Only where it holds at most this share. Default 1."},"vertices":{"type":"array","items":{"type":"number"},"description":"Explicit vertex indices instead of a selection. For a caller that already knows which ones — get_weights reports them, and a script can compute them."},"exclusive":{"type":"boolean","description":"Also take those vertices off every other dot's pins, which is what 'these belong to this dot' means. Default true; false leaves rival pins and the vertex is divided between them."},"reset":{"type":"boolean","description":"Take every pin off the rig and ignore everything else — paint_weights' rows included, since they are pins too."}},"required":["dot"]}`,
		.handler = &tool_pin_weights,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "fix_strays",
		.description = "Put back every stray get_weights lists — an island of a dot's weight cut off from the rest of it, which a pose pulls out of the body as a spike. Each goes back to the automatic weights, its pins cleared, since a stray is nearly always an edit's leftover; where the automatic weights made it, it takes the weights of the mesh around it instead. One call is one undo step. The Weights card's Find strays and Fix strays are the same two calls. Answers how many strays it found, how many vertices it changed, and the strays left, as get_weights lists them.",
		.input_schema = `{"type":"object","properties":{}}`,
		.handler = &tool_fix_strays,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "get_shells",
		.description = "The mesh's separate pieces: id, how many vertices, where it sits, how big it is, and which dot it has been pinned to. A piece is a run of surface nothing joins to the rest, so a hard-surface model — an animatronic, a mech, anything panelled — arrives as dozens of them. Pinning one to a dot with edit_rig's attach makes it move rigidly with that dot however the falloff would have weighted it, which is the answer for a part that should not deform at all. A piece also carries auto when the binder froze it onto a bone by itself — a prop the flood never reached, or a piece that turned out to be one bone's outright — so a part that is already rigid does not get pinned twice; the field is absent when there is no such choice and while the rig has moved since the last bind. Largest first, so the body and the head are the first rows.",
		.input_schema = `{"type":"object","properties":{"limit":{"type":"number","description":"How many pieces to list, largest first. Default 40; a shattered mesh can hold thousands and the small ones are rivets."}}}`,
		.handler = &tool_get_shells,
		.user_data = app,
		.hidden = true,
	});
	// Two tools three brings its own of, registered only when there is no engine
	// to serve them (the tests). Three's versions win: `install_tools` skips a
	// name the server already holds, which is what keeps `--mcp-stdio`'s catalog
	// from listing these twice.
	//
	//   screenshot   three renders into the same target crig's interface is
	//                composited onto, so its picture is this one — viewport,
	//                panels, dots and all.
	//   get_api_docs crig's document is a section of three's.
	if (!hosted()) server.add_tool({
		.name = "screenshot",
		.description = "A PNG of Rigsmith's window as it stands: the viewport, the panels, the dots, whatever is playing. The visual eyes to get_pose's numeric ones — the answer to whether something is drawn where it should be, hidden behind a panel, or not drawn at all. Draws a fresh frame, so it shows the effect of a tool called just before it.",
		.input_schema = `{"type":"object","properties":{}}`,
		.handler = &tool_screenshot,
		.user_data = app,
		// The one answer here that is not text; see `screenshot_content`.
		.raw_content = true,
	});
	server.add_tool({
		.name = "render",
		.description = "Photograph a clip at instants nobody is watching, tiled into one PNG, each tile labelled with its time. Give it four to nine times over a cycle, or {\"keys\": true} for every keyframe the clip has (keys: [0, 2, 5] for some of them), and a view to look from, and what comes back is a contact sheet — which is how a walk is read, because a foot that plants and a foot that skates are the same picture one frame at a time. The player and the camera are put back exactly as they were, so this costs the person at the screen a flicker. screenshot is the tool for what they are actually looking at; measure_clip is the one for anything with a number attached, since foot_slide and floor_penetration are precisely what a picture hides.",
		.input_schema = RENDER_SCHEMA,
		.handler = &tool_render,
		.user_data = app,
		// An image, like screenshot's; see `screenshot_content`.
		.raw_content = true,
	});
	server.add_tool({
		.name = "set_camera",
		.description = "Aim the viewport for the person in front of it. {\"frame\": true} centres it on the character being edited, wherever that character stands in the scene, and backs off until all of it is in view — the fix when a screenshot shows only empty floor. Or one of the six axis views, or yaw, pitch, distance and target (model space) by hand. render takes its own camera arguments and puts the camera back, so a picture never needs this first.",
		.input_schema = SET_CAMERA_SCHEMA,
		.handler = &tool_set_camera,
		.user_data = app,
	});
	if (!hosted()) server.add_tool({
		.name = "get_api_docs",
		.description = "The conventions every tool follows, and every tool's own arguments. No arguments answers with an index: a line naming each section — quality, clips, authoring, turning, targets, editing, playback, cycles, ground, gaits, looking, rigging, scripting, weights, physics, review, layers, pins, repair — and the name of every registered tool, listed or not. {\"topic\":\"ground\"} returns one section in full and {\"topic\":\"all\"} returns the lot, which is some twelve thousand characters. {\"tool\":\"apply_clip\"} returns that tool's description and JSON Schema off the registration itself, which is how to read the arguments of the tools that are not in this list without writing a script to ask. Read the conventions before authoring anything: they are what no schema has room for.",
		.input_schema = `{"type":"object","properties":{
	"topic":{"type":"string","description":"A section name from the index, or \"all\" for every section. Omit for the index."},
	"tool":{"type":"string","description":"A tool's own description and JSON Schema, from the registry the wire validates against. The same answer a script gets from crig.help(name)."}
}}`,
		.handler = &tool_get_api_docs,
		.user_data = app,
	});
	// crig's own documentation, under a name three does not already own — so it is
	// reachable on the hosted build, where `get_api_docs` is three's and answers
	// for the scene. Listed, because a client that never sees this one does not
	// know crig has a surface past three's scene at all: it is the door onto the
	// twenty-odd hidden tools and the conventions no schema has room for.
	server.add_tool({
		.name = "get_crig_docs",
		.description = "Rigsmith's conventions and its tool reference — the half three's get_api_docs, which answers for the scene, does not carry. No arguments gives an index: the sections (quality, clips, authoring, turning, targets, editing, playback, cycles, ground, gaits, looking, rigging, scripting, weights, physics, review, layers, pins, repair) and every tool's name, listed or not. Read quality first: it is the bar a clip has to clear and the loop that gets it there. {\"topic\":\"ground\"} returns one section, {\"topic\":\"all\"} every section. {\"tool\":\"apply_clip\"} returns that tool's description and JSON Schema off the registry the wire validates against, which is how to read the arguments of the hidden tools. A run_script body gets the same answers from crig.help(name).",
		.input_schema = `{"type":"object","properties":{
	"topic":{"type":"string","description":"A section name from the index, or \"all\" for every section. Omit for the index."},
	"tool":{"type":"string","description":"A tool's own description and JSON Schema. The same answer a script gets from crig.help(name)."}
}}`,
		.handler = &tool_get_api_docs,
		.user_data = app,
	});
	// Saving the project, as against publishing a pack: this writes the open
	// document in place — the rig into the model, the rest into its .rigsmith.json
	// sidecar — while save_pack writes a reusable library file and leaves the
	// project's own copies alone. Hidden like most; get_scene's authored_dirty is
	// the listed cue that a save is owed, and the docs name this as the answer.
	server.add_tool({
		.name = "save_project",
		.description = "Save the open project in place: the rig written into the model, and the rest — dot ids, reaches, pins, mirror plane, pose, paint — into the model's .rigsmith.json sidecar beside it, which is what a later open reads back. This is the project, not the library: save_pack publishes reusable clips into the animation library and leaves the project's own editable copies and their bindings untouched, and this does the opposite. Answers with the file written and whether authored changes remain unsaved; get_scene reports the same authored_dirty flag without writing. A model Rigsmith did not author is copied to <stem>_copy.glb on the first save, so a source asset is never overwritten.",
		.input_schema = `{"type":"object","properties":{}}`,
		.handler = &tool_save_project,
		.user_data = app,
		.hidden = true,
	});
	// Placing a hand or a foot at a point without composing the joints above it by
	// hand — the limit-aware chain solver a finger's curl runs, exposed for
	// authoring. Listed, because it is the answer to the hardest part of writing a
	// clip by MCP: guessing shoulder and elbow angles until the hand lands right.
	server.add_tool({
		.name = "solve_targets",
		.description = "Place hands and feet at points and answer with the pose that reaches them — the joints above each effector bent by Rigsmith's limit-aware IK, so a clip can be authored without composing shoulder and elbow quaternions by hand. Each target is a joint and a model-space position, optionally relative to another joint (\"hands ahead of the knees\") and with an orientation to hold once placed (a palm down, a foot flat). The answer is a residual per target and a keyframe in exactly apply_clip's shape: this tool solves, apply_clip bakes it to ordinary editable keys, the same read-then-write round trip get_clip and apply_clip are. It writes nothing and spends no undo step, so a caller can read the residuals, nudge a target and solve again before committing. A target may carry a pole point to settle which way a two-bone limb bends — the elbow or knee is turned to point at it after the reach, honouring the joint's limits and leaving the effector where the reach put it. A coupled reach-and-twist solve — position and orientation at once — is not here yet; orientation is held after the reach.",
		.input_schema = SOLVE_TARGETS_SCHEMA,
		.handler = &tool_solve_targets,
		.user_data = app,
	});
	// The horizontal half of a ground contact, which ground_pose's root-Y solve
	// cannot reach: holding a stance foot in place while the pelvis moves needs the
	// leg to bend, not the root to slide. Bakes that bend across each stance window
	// and lands it, so a clip stops skating. Hidden — it is the second step of a
	// ground workflow measure_clip and the ground docs point at, not an orientation
	// call.
	// The additive counterpart to apply_clip: a few joints offset over a range,
	// every other track left alone, in one undo step. Hidden — it is a step inside
	// an editing loop (read a clip, offset one arm, measure), reached by name or from
	// a script, not a first call a client needs a schema in front of it for.
	server.add_tool({
		.name = "patch_clip",
		.description = "Offset a few joints of a clip over a range without rewriting the rest of it — the additive counterpart to apply_clip, for lowering a hand or leaning a spine when the whole clip is otherwise right. Each joint takes a rotation offset, a move offset, or both, composed onto the value the clip already has there rather than replacing it; every other joint, every other channel, the interpolation and the ground spec are left exactly as they were. Omit range for a uniform offset across the whole clip, or give {\"phase\":[a,b]} or {\"time\":[a,b]} to hold the offset over a span and ease it in and out through the clip's own interpolation just outside it. space is \"local\" (the joint's parent frame, the default, no rig needed) or \"world\" (the model's own axes, which reads the rig to convert) — the same distinction apply_clip's space draws, explained in the turning docs. It lands in the authored pack as one undo step. It does not retime, resample a channel the joint does not key, or change grounding.",
		.input_schema = PATCH_CLIP_SCHEMA,
		.handler = &tool_patch_clip,
		.user_data = app,
		.hidden = true,
	});
	// Text to motion through the built-in llm pipeline (llm.c3l). Hidden with the rest of
	// the authoring tools: a clip made this way is then an ordinary bound clip,
	// and the tools that measure and fix one are where a session goes next.
	server.add_tool({
		.name = "generate_motion",
		.description = "Generate an animation from a sentence and bind it to the character. Rigsmith runs NVIDIA's Kimodo text-to-motion model on its own GPU through the built-in llm pipeline (the weights are chosen in File › Settings › AI), and the clip it writes comes in like any downloaded clip: matched onto this rig's body plan by shape and bound, in place. It takes ten to thirty seconds, so the call starts the job and answers at once with state running; call it again with no prompt to follow it, until state is done (the clip's name, now playable by play, measurable by measure_clip, repairable with make_loop, smooth_clip, pin_feet and patch_clip — see get_crig_docs topics repair and quality; a take is not done until measure_clip reads usable) or failed (the reason). One job runs at a time. When the prompt alone gives a broken motion, key the poses it has to hit in a clip and pass that clip as poses_from: Kimodo passes through each keyed pose at its time and makes the motion between.",
		.input_schema = GENERATE_MOTION_SCHEMA,
		.handler = &tool_generate_motion,
		.user_data = app,
		.hidden = true,
	});
	// Listed: bringing motion in from a file is a first call a session makes, not
	// a step inside a loop, and no other door does it without a library rescan.
	server.add_tool({
		.name = "import_clip",
		.description = "Bring an animation in from a .glb file and bind it to the character — motion made for any other skeleton: a capture, SAM 3D Body's MHR clip, a Mixamo download, another rig's clip. It comes in the way generate_motion's clips do: the file's skeleton matched onto this rig's body plan by shape, the clip sampled onto the rig's own joints and landed in the authored pack as one undo step, editable, not looping, in place (the root's travel is removed). Answers as apply_clip does, with measure_clip's numbers under metrics; make_loop, smooth_clip and pin_feet are how a take becomes a cycle. Refused when the file cannot be read, holds no animation, or its skeleton matches no body plan this rig shares.",
		.input_schema = IMPORT_CLIP_SCHEMA,
		.handler = &tool_import_clip,
		.user_data = app,
	});
	// Hidden: a training set is drawn in a loop of calls by whoever trains on it
	// (llm-runner's creature plugin), not chosen by a session that is rigging.
	server.add_tool({
		.name = "render_poses",
		.description = "Draw the character in random poses inside its joint limits, from given cameras, for training a joint finder on this rig (llm-runner's creature /train). Each picture is an RGBA PNG with a transparent background — nothing but the mesh: no interface, floor or overlay — and poses_<first>.json beside them gives every joint's pixel and depth per picture, and every joint's turn per pose. The same seed and index always draw the same picture, so a set of thousands is drawn a few hundred poses a call (count, first); the window stands still for the length of a call. With motion it draws an exam instead: one smooth movement, a frame per index, from cameras held still. The document is not touched.",
		.input_schema = RENDER_POSES_SCHEMA,
		.handler = &tool_render_poses,
		.user_data = app,
		.hidden = true,
	});
	// --- clip management tools ---
	server.add_tool({
		.name = "unbind_clip",
		.description = "Take a bound clip off the character, as one undo step. The clip stays in its pack or file and can be bound again; it simply stops being one of the character's animations, so the next Save no longer writes it into the model. get_scene lists what is bound.",
		.input_schema = UNBIND_CLIP_SCHEMA,
		.handler = &tool_unbind_clip,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "delete_model_clip",
		.description = "Delete one of the loaded model's own clips: unbind it and re-save the model without it, which is how an animation leaves the glb for good. Refused when no model is open, when the document has no mesh to re-save, or when the clip is not one the loaded file holds (a library file is not this model's to rewrite; delete_clip removes an authored clip and unbind_clip only drops a binding). It re-saves the model, so it cannot be undone with undo.",
		.input_schema = DELETE_MODEL_CLIP_SCHEMA,
		.handler = &tool_delete_model_clip,
		.user_data = app,
		.hidden = true,
	});
	// --- gait tools ---
	server.add_tool({
		.name = "author_gait",
		.description = "Write a walk, trot, pace or gallop cycle for the rig's own legs — and, on an upright two-legged figure, the rest of a walking body: pelvis bob and turn, a chest turning against it, arms lowered and swinging opposite the legs, a level head (upper_body false for legs only). Every leg is solved inside the rig's joint limits, so the keys are what plays. It lands as ordinary editable keys in the authored pack (one undo step). Name a gait and a duration and it finds the feet (each left/right pair of limbs near the floor that ends in a toe), draws every foot's path — stance slides back at a constant speed along the floor, swing carries it forward through a lifted arc — and solves each two-to-four-bone leg onto it: analytic IK in the plane the rest leg bends in (so splayed legs work), the knee bending the side it rests on, a longer leg's distal segment holding its tilt and tilting only as far as the reach needs. Each foot keeps its own place in the cycle (walk is the lateral sequence, trot the diagonals, pace the lateral pairs, gallop the rotary order; custom takes every foot's offset) and the clip carries a ground spec of when each is down, so the root height is the floor solve's. The figure does not travel: ground_speed is the treadmill its stance feet run at, in model units per second. Answers with the landed clip, measure_clip's numbers for it and that speed.",
		.input_schema = AUTHOR_GAIT_SCHEMA,
		.handler = &tool_author_gait,
		.user_data = app,
		.hidden = true,
	});
	// --- layers tools ---
	server.add_tool({
		.name = "set_layer",
		.description = "Add, replace, remove or reorder one layer of a clip's stack without resending the clip. A layer is an adjustment laid over the clip's own keys: sparse keyed deltas (a breath, a limp), or a generator — a wave travelling down a chain of joints such as a tail, seeded noise, or one pulse at a moment — with a weight, an optional time range and fades, and an optional joint mask. Additive layers add to what is underneath; override layers blend it toward the layer. The stack is evaluated inside the pose sampler before retargeting, so playback, get_pose, measure_clip, bake_physics and every baked export see it. Layers live in the project sidecar (save_project); a saved or exported file gets the flattened result. One call is one undo step. op extract lifts the keys of chosen joints (a tail) out of the base into a layer of their own, the pose unchanged; op share links the layer into other clips so one edit changes them all, each fitting it to its own length; op unlink makes a copy independent again. Read the layers topic of get_crig_docs for the model; merge_layers bakes the stack into ordinary keys.",
		.input_schema = SET_LAYER_SCHEMA,
		.handler = &tool_set_layer,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "merge_layers",
		.description = "Bake a clip's unmuted layers into its own keys and clear the stack, for a clip that should stop being layered. The result is dense-enough linear keys sampled from the layered clip (the ground spec is kept); muted layers are dropped. With into, the baked keys land as a new clip of that name and the source keeps its layers. One undo step.",
		.input_schema = MERGE_LAYERS_SCHEMA,
		.handler = &tool_merge_layers,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "duplicate_clip",
		.description = "Copy a clip under a new name in the authored pack and bind the copy — the Animations pane's Duplicate. The copy keeps the keys, layers, ground spec, pins and aims, so a variant can be tried without touching the original; a library clip comes over in this rig's joint names. One undo step. Answers as apply_clip does.",
		.input_schema = DUPLICATE_CLIP_SCHEMA,
		.handler = &tool_duplicate_clip,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "blend_in",
		.description = "Write a one-shot clip that starts from the rest pose (a T-pose, on a rig that rests in one) or a saved pose, holds it, eases into another clip at a phase of its cycle, then follows that clip for some cycles — the opening of a shot, where a figure comes out of its bind pose into a walk already under way. The clip's layers are baked into the new keys, and its ground spec is carried with every contact window moved onto the new timing: a foot down where the blend lands is down from the start, one in the air there lifts half way through the blend. Lands in the authored pack, not looping, as one undo step; answers as apply_clip does.",
		.input_schema = BLEND_IN_SCHEMA,
		.handler = &tool_blend_in,
		.user_data = app,
		.hidden = true,
	});
	// --- aim tools ---
	server.add_tool({
		.name = "get_aims",
		.description = "A clip's look-at targets and the locks on them: targets are named points (name, mute, keyed positions in model space as a fraction of rig height); locks name a joint, the target it turns toward, its aim axis and how the turn is spread over it and its parents (spread, weights, influence, mute). Targets and locks are laid over the pose when it is shown, played or exported and are never written into the clip's keys. They live in the project sidecar (save_project).",
		.input_schema = GET_AIMS_SCHEMA,
		.handler = &tool_get_aims,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "set_aim_target",
		.description = "Create, key, mute or remove a look-at target, a named point in space joints can lock to (see set_aim). A missing or new name creates a target and needs at, [x,y,z] in model space as a fraction of rig height; the default name is the lowest unused \"Target N\". On an existing target, at keys a new position at time and mute silences it and its locks; remove deletes it and every lock on it. One call is one undo step.",
		.input_schema = SET_AIM_TARGET_SCHEMA,
		.handler = &tool_set_aim_target,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "set_aim",
		.description = "Lock a joint, usually the head or a finger, to a look-at target so it turns toward the target, or retune or remove the lock, without resending the clip. Any number of joints may lock to one target. The turn is spread over the joint and a few parents (head, neck, chest, about 50/30/20) and still obeys the joints' limits, and it is applied live on top of the clip's own keys, so muting or removing it gives the authored motion back exactly. A new lock captures its aim axis from the direction to the target on the clip's pose at time, so locking turns nothing. spread (1 to 4), weights, influence (0 to 1) and mute retune it; remove deletes it. One call is one undo step.",
		.input_schema = SET_AIM_SCHEMA,
		.handler = &tool_set_aim,
		.user_data = app,
		.hidden = true,
	});
	// --- pin tools ---
	server.add_tool({
		.name = "get_pins",
		.description = "The pins holding joints in place while another is posed — the Joint panel's Pin position and Pin angle — and how well they held. Each entry names the joint, which halves are on (position, rotation), the point a position pin holds, and what the last pose left it from that point: residual in model units, residual_fraction of rig height, turn_residual in radians for a held angle; a pin that could not hold — out of its limb's reach, or against another pin — is one with a residual above zero. Beside the list: balance (whether the body leans to keep its weight over pinned feet), pose_unkeyed (a posed but unkeyed pose is showing), and the clip and time the pose is at. With no clip open pins are working memory of the session, not saved with the project; with a clip open they are the clip's own pins (saved with it, held in playback and export): pins lists those whose window covers the playhead and clip_pins every one with from, to and blend in seconds. See the pins topic of get_crig_docs.",
		.input_schema = GET_PINS_SCHEMA,
		.handler = &tool_get_pins,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "set_pins",
		.description = "Pin joints where they stand on screen, or let them go, so a later pose_joint holds them still: pin both hind paws and pull the pelvis down and the legs fold into a sit with the paws staying put. Each pin holds the joint's position, its orientation (a foot kept flat), or both, captured from the pose showing now — give clip and time to choose which pose that is, otherwise the clip open in the timeline at its playhead. clear drops every pin first, and balance switches the lean that keeps the body's weight over pinned feet. With a clip open the pins are the clip's: they hold the joint while the clip plays and in the export, over each pin's from..to window (default the whole clip) with a blend (seconds, default 0.1) easing at its ends, and each pin is one undo step. Answers with get_pins' state. A joint named that the rig does not have refuses the whole call and changes nothing.",
		.input_schema = SET_PINS_SCHEMA,
		.handler = &tool_set_pins,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "trim_clip",
		.description = "Cut a clip down: keep [start, end] seconds and drop the rest (the clip then starts at start), or cut [start, end] out and close the gap. Contact windows, pins and layers move with the keys. One undo step; answers with the clip and measure_clip's numbers. What the Animations pane's Trim does — the first repair for a generated take that starts from a stand or trails off.",
		.input_schema = TRIM_CLIP_SCHEMA,
		.handler = &tool_trim_clip,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "retime_clip",
		.description = "Stretch or squeeze a whole clip to a new length in seconds: every key, contact window and pin moves with it, so a walk's footfalls stay where they fall in the cycle. One undo step.",
		.input_schema = RETIME_CLIP_SCHEMA,
		.handler = &tool_retime_clip,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "optimize_clip",
		.description = "Drop the keys a clip can lose without moving differently: whole keys first, then single joints' keys, checked against the clip as it was within a quarter of a degree (light) or a degree (strong). One undo step; answers with the keys left.",
		.input_schema = OPTIMIZE_CLIP_SCHEMA,
		.handler = &tool_optimize_clip,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "remove_movement",
		.description = "Stop a clip travelling: hold the hips over where they start (or move the travel onto a root joint), optionally taking out its turn about the vertical too — what the Animations pane's Optimize does with translation and rotation ticked. One undo step.",
		.input_schema = REMOVE_MOVEMENT_SCHEMA,
		.handler = &tool_remove_movement,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "close_loop",
		.description = "Restate a looping clip's first pose at its end, so the seam does not jump. One undo step.",
		.input_schema = CLOSE_LOOP_SCHEMA,
		.handler = &tool_close_loop,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "remove_keys",
		.description = "Remove keyframes from a clip, by index (counted from 0 as get_clip lists them) or every partial one — a key that names fewer joints than the clip's fullest. The repair for a pop measure_clip localizes to a key: a leftover correction key between whole poses that jerks a leg for a few milliseconds. With joints, removes every key of those joints and the joints below them instead, leaving them at rest: the tail of a clip that should not move (set_layer op extract keeps the motion as a layer instead). One undo step; answers with measure_clip's numbers.",
		.input_schema = REMOVE_KEYS_SCHEMA,
		.handler = &tool_remove_keys,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "smooth_clip",
		.description = "Filter jitter out of a clip: every key's value becomes a Gaussian average of the curve round it over window seconds, the keys staying where they are. Rotations are averaged as rotations. Planted feet and pinned joints are left alone while held (hold_contacts), a joints list or a range narrows it, and the filter eases in and out at a range's edges. The fix for a generated clip whose hands tremble or whose spine buzzes. One undo step; answers with measure_clip's numbers.",
		.input_schema = SMOOTH_CLIP_SCHEMA,
		.handler = &tool_smooth_clip,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "make_loop",
		.description = "Cut a seamless cycle out of a take — a generated walk, run or climb — as a new looping clip: it finds the start and period whose two poses match best (in pose and in speed), crossfades the last stretch into what led into the start so the seam flows, closes it, takes the root's sideways drift off and thins the keys. Give period as the range a cycle may last (a walk's two steps are about 0.9 to 1.3 s). Answers with where it cut, how far apart the seam's poses were, and measure_clip's numbers for the cycle.",
		.input_schema = MAKE_LOOP_SCHEMA,
		.handler = &tool_make_loop,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "pin_feet",
		.description = "Hold feet on the floor while a clip plays: each window a foot is down becomes a live clip pin that bends the leg to keep the foot in place — on the floor, flat, and still (or sliding back at travel, the treadmill speed of an in-place cycle). The pins stay editable (get_pins, set_pins, the pin lanes on the sheet) and bake into keys only on export, so nothing is lost if they are wrong; clear takes them off. windows \"auto\" (the default) reads them from the clip's ground spec, or, for a foot it does not name, off the motion itself — every time the foot comes down, so a jump's takeoff and landing are two windows. One undo step. Answers with each pin written and the worst distance its foot strayed from it inside the window (a fraction of rig height): a large one means the leg cannot reach — a limit, or a window that runs into the swing.",
		.input_schema = PIN_FEET_SCHEMA,
		.handler = &tool_pin_feet,
		.user_data = app,
		.hidden = true,
	});
	server.add_tool({
		.name = "pose_joint",
		.description = "Drag or turn one joint of a clip at a time and key the result — the viewport gesture, made from a script. It runs the very calls the mouse does (the Pose stage, the same whole-body solve with pins, balance and joint limits, and a grounded clip's floor solve) and, with key (the default), keys it as releasing the mouse does with Auto-key on. move is [x,y,z] model units to move the joint by, target an absolute point; turn is {axis, angle} in radians about a world axis and follows a move. With pins set (set_pins) a move of the hips or pelvis carries the body over them. The answer gives where the joint ended against where it was asked to go (miss, in model units and as a share of rig height), whether the pose was keyed, and get_pins' state, whose residuals say how far each pin held. key false leaves the pose showing unkeyed; a later call with key true and nothing else keys it. The clip and time default to the ones open in the timeline; a library clip is forked into the authored pack when keyed.",
		.input_schema = POSE_JOINT_SCHEMA,
		.handler = &tool_pose_joint,
		.user_data = app,
		.hidden = true,
	});
	// Last: the cast, and the tools that are about more than one character.
	add_cast_tools(&server, app);
	return server;
}

// ---------------------------------------------------------------------------
// Tool handlers: thin adapters from the wire to the builder that does the work,
// wherever it lives. A handler with any length to it is reading arguments — the
// shape that arrives off a socket is nobody's promise, and checking it is the
// handler's job rather than the builder's.

fn String? tool_get_scene(Object* args, void* user_data, DString* detail) @private
	=> scene_json((AppState*)user_data);

fn String? tool_save_project(Object* args, void* user_data, DString* detail) @private
	=> save_project_json((AppState*)user_data);

fn String? tool_solve_targets(Object* args, void* user_data, DString* detail) @private
	=> solve_targets_json((AppState*)user_data, args, detail);

fn String? tool_patch_clip(Object* args, void* user_data, DString* detail) @private
	=> patch_clip_json((AppState*)user_data, args, detail);

fn String? tool_set_layer(Object* args, void* user_data, DString* detail) @private
	=> set_layer_json((AppState*)user_data, args, detail);

fn String? tool_get_aims(Object* args, void* user_data, DString* detail) @private
	=> get_aims_json((AppState*)user_data, args, detail);

fn String? tool_set_aim_target(Object* args, void* user_data, DString* detail) @private
	=> set_aim_target_json((AppState*)user_data, args, detail);

fn String? tool_set_aim(Object* args, void* user_data, DString* detail) @private
	=> set_aim_json((AppState*)user_data, args, detail);

fn String? tool_merge_layers(Object* args, void* user_data, DString* detail) @private
	=> merge_layers_json((AppState*)user_data, args, detail);

fn String? tool_get_skeleton(Object* args, void* user_data, DString* detail) @private
	=> skeleton_json((AppState*)user_data);

fn String? tool_get_pose(Object* args, void* user_data, DString* detail) @private
{
	// `get_string` on a value that is not an object is a contract failure, not a
	// fault, so the shape is checked before anything is read out of it: what
	// arrives here came off a socket and is nobody's promise.
	if (!takes_object(args, detail, `get_pose takes an object: {"clip": name, "t": seconds from the clip's start}. get_scene lists every pack and clip.`)) return POSE_BAD_ARGS~;
	String clip;
	if (!required_string(args, "clip", &clip, detail, `get_pose needs "clip": the name of a clip in the library. get_scene lists every pack and clip.`)) return POSE_BAD_ARGS~;
	double t = 0;
	if (try given = args.get_float("t")) t = given;
	return pose_json((AppState*)user_data, clip, (float)t, detail);
}

<*
 The one tool that writes. Parsing and validation are `parse_clip`'s, in
 clip.c3; what is left here is the handover — the template it returns is
 owned by the pack from the moment it is put there, and by nobody before.
*>
fn String? tool_apply_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	AnimTemplate clip = parse_clip(app, args, detail)!;

	bool replaced;
	// author_clip, not put_authored_clip: an authored clip binds into the
	// timeline and becomes the editing clip, so the person at the screen can
	// select, scrub and pause it. A clip that only reaches the pack plays but
	// leaves the transport controlling whatever clip the timeline still holds.
	//
	// One tool call, one undo step — the same rule `edit_rig` follows. author_clip
	// commits the clip swap and its binding together, so a script writing hundreds
	// of keys is one Ctrl+Z rather than one per key.
	AnimRef ref = app.author_clip(clip, &replaced);
	app.refresh_ui();
	return applied_json(app, ref, replaced);
}

<*
 The other tool that writes a clip, and the only one whose keys nobody typed.

 Parsing, validation and the bake itself are `bake_physics_json`'s, in
 physics.c3; what is left here is the same handover `tool_apply_clip` does.
*>
fn String? tool_bake_physics(Object* args, void* user_data, DString* detail) @private
	=> bake_physics_json((AppState*)user_data, args, detail);

fn String? tool_get_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `get_clip takes an object: {"clip": name}. get_scene lists every pack and clip.`)) return POSE_BAD_ARGS~;
	String clip;
	if (!required_string(args, "clip", &clip, detail, `get_clip needs "clip": the name of a clip in the library. get_scene lists every pack and clip.`)) return POSE_BAD_ARGS~;
	return clip_json(app, clip, detail);
}

fn String? tool_measure_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `measure_clip takes an object: {"clip": name, "samples": how many instants to look at}. get_scene lists every pack and clip.`)) return POSE_BAD_ARGS~;
	String clip;
	if (!required_string(args, "clip", &clip, detail, `measure_clip needs "clip": the name of a clip in the library. get_scene lists every pack and clip.`)) return POSE_BAD_ARGS~;

	double samples = args.get_float("samples") ?? 0.0;
	if (samples != 0.0 && (samples < 2 || samples > MEASURE_SAMPLE_LIMIT))
	{
		detail.appendf(
			`"samples" is %.9g. Two is the fewest that says anything and %d is as many as the answer is worth; leave it out for sixty a second of clip.`,
			samples, MEASURE_SAMPLE_LIMIT);
		return POSE_BAD_ARGS~;
	}
	return metrics_json(app, clip, (usz)samples, detail);
}

<*
 delete_clip: an animation deleted for good — `AppState.delete_animation`, the same
 work the asset browser's Delete does.

 Named as every clip tool names one (`resolve_named`): a bare name, or "Pack/Clip".
 The clip must be the project's own — authored, or one of the loaded model's file —
 since a library file is not this model's to rewrite; `unbind_clip` takes any clip
 off the character.
*>
fn String? tool_delete_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `delete_clip takes an object: {"clip": name}`)) return CLIP_NOT_FOUND~;
	String asked;
	if (!required_string(args, "clip", &asked, detail, `delete_clip needs "clip": the clip's name, or "Pack/Clip".`)) return CLIP_NOT_FOUND~;

	AnimRef ref = resolve_named(app, asked, detail)!;
	AnimTemplate* clip = app.clip(ref);
	if (!clip) return CLIP_NOT_FOUND~;
	bool own_file = app.source_path.len > 0 && ref.pack == app.loaded_pack_for(app.source_path);
	if (ref.pack != app.authored_pack && !own_file)
	{
		AnimPack* pack = app.pack((usz)ref.pack);
		detail.appendf(`"%s" is in %s, a library file, which is not this project's to rewrite. `
			`delete_clip deletes the project's own clips (authored, or the loaded model's); unbind_clip takes this one off the character.`,
			clip.name, pack ? base_name(pack.path) : "another pack");
		return CLIP_NOT_FOUND~;
	}

	String named = clip.name.copy(mem);
	defer named.free(mem);
	if (!app.delete_animation(named, detail)) return CLIP_NOT_FOUND~;
	return deleted_json(app, named);
}

fn String? tool_apply_plan(Object* args, void* user_data, DString* detail) @private
	=> apply_plan((AppState*)user_data, args, detail);

fn String? tool_edit_rig(Object* args, void* user_data, DString* detail) @private
	=> edit_rig((AppState*)user_data, args, detail);

<*
 The rig edit that changes no dot: which chains of bones the physics owns.

 Beside `edit_rig` rather than beside `bake_physics` in every respect but the
 file it lives in — one undo group, all-or-nothing, the same recorded setters the
 viewport uses. Parsing and validation are `set_secondary_motion_json`'s, in
 physics.c3.
*>
fn String? tool_set_secondary_motion(Object* args, void* user_data, DString* detail) @private
	=> set_secondary_motion_json((AppState*)user_data, args, detail);

fn String? tool_build_body(Object* args, void* user_data, DString* detail) @private
	=> build_body_json((AppState*)user_data, args, detail);

fn String? tool_undo(Object* args, void* user_data, DString* detail) @private
	=> step_history((AppState*)user_data, args, false, detail);

fn String? tool_redo(Object* args, void* user_data, DString* detail) @private
	=> step_history((AppState*)user_data, args, true, detail);

fn String? tool_scale_model(Object* args, void* user_data, DString* detail) @private
	=> scale_model_tool((AppState*)user_data, args, detail);

fn String? tool_screenshot(Object* args, void* user_data, DString* detail) @private
	=> screenshot_content((AppState*)user_data, detail);

fn String? tool_render(Object* args, void* user_data, DString* detail) @private
	=> render_content((AppState*)user_data, args, detail);

fn String? tool_set_camera(Object* args, void* user_data, DString* detail) @private
	=> set_camera_json((AppState*)user_data, args, detail);

// ---------------------------------------------------------------------------
// The reads: what the document says, with nothing changed to say it.

<*
 get_scene: mesh stats, bounds, the conventions an author needs up front,
 the rig's counts, the whole animation library, and what is playing.
*>
fn String scene_json(AppState* app)
{
	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"mesh":{"source":"`);
	json_escape_into(&out, app.source_path);
	out.append_string(`","vertices":`);
	out.appendf("%d", app.geometry.positions.len);
	out.append_string(`,"triangles":`);
	out.appendf("%d", app.geometry.triangle_count());
	out.append_string(`,"has_normals":`);
	out.append_string(app.geometry.has_normals() ? "true" : "false");

	rig::Bounds bounds = app.geometry.bounds();
	out.append_string(`},"bounds":{"min":`);
	append_vec3(&out, bounds.min);
	out.append_string(`,"max":`);
	append_vec3(&out, bounds.max);
	out.append_string(`,"size":`);
	append_vec3(&out, bounds.extent());

	out.append_string(`},"space":{"axes":"glTF: +Y up, the model faces +Z","positions":"model space, unnormalised","time":"seconds","angles":"radians","move":"fraction of rig height"}`);

	out.append_string(`,"rig":{"dots":`);
	out.appendf("%d", app.doc.dots.len());
	out.append_string(`,"edges":`);
	out.appendf("%d", app.doc.edges.len());
	out.append_string(`,"root":`);
	out.appendf("%d", app.doc.root_id);
	out.append_string(`,"plan":"`);
	json_escape_into(&out, app.doc.plan);
	// The plane the M-key mirror reflects across — its default is the mesh's
	// bounding-box centre, which edit_rig's symmetry op corrects for an asymmetric
	// mesh whose centre is not the body's midline.
	out.appendf(`","symmetry_x":%s`, (JsonFloat)app.doc.sym_x);
	append_rig_issues(&out, app, true);
	out.append_char('}');

	// Whether the project has authored changes not yet in its sidecar, and whether
	// crig owns the file it would save into (else the first save_project makes a
	// copy). The cue an agent reads before it decides a save is owed.
	out.appendf(`,"annotations":%d`, app.annotations.len());
	// The pose library by name, so "animate from walk-start to walk-end" needs no
	// lookup first; get_saved_pose reads one.
	out.append_string(`,"saved_poses":[`);
	foreach (i, pose : app.doc.poses)
	{
		if (i > 0) out.append_char(',');
		append_json_string(&out, pose.name);
	}
	out.append_char(']');
	out.append_string(`,"project":{"authored_dirty":`);
	out.append_string(app.authored_dirty ? "true" : "false");
	out.append_string(`,"saves_in_place":`);
	out.append_string(app.saves_in_place ? "true" : "false");
	out.append_char('}');

	// The self-collision check as it stands: whether the system is switched
	// on at all, whether posing is blocked at the body, how close counts, how
	// much of the check this mesh gets, and what the last checked gesture met
	// — the reason a pose came back short of what a tool asked for.
	out.appendf(`,"collision":{"enabled":%s,"prevent":%s,"clearance":%.6g,"mode":"%s","rest_contacts":%d`,
		app.config.self_collision, !app.doc.allow_intersections, app.collision_clearance_fraction(),
		app.collision_mode.label(), app.collision_policy.rest_contacts.len);
	if (app.last_block.tested)
	{
		out.appendf(`,"last":{"blocked":%s,"tests":%d,"ms":%.3g`,
			app.last_block.blocked, app.last_block.tests, app.last_block.seconds * 1000.0f);
		if (app.last_block.contact.hit)
		{
			out.append_string(`,"against":["`);
			json_escape_into(&out, app.contact_region_name(app.last_block.contact.pair.a));
			out.append_string(`","`);
			json_escape_into(&out, app.contact_region_name(app.last_block.contact.pair.b));
			out.append_string(`"]`);
		}
		out.append_char('}');
	}
	out.append_char('}');

	out.append_string(`,"packs":[`);
	foreach (p, pack : app.packs)
	{
		if (p > 0) out.append_char(',');
		out.append_string(`{"name":"`);
		json_escape_into(&out, pack.name);
		out.append_string(`","plan":"`);
		json_escape_into(&out, pack.plan);
		out.append_string(`","clips":[`);
		foreach (c, clip : pack.clips)
		{
			if (c > 0) out.append_char(',');
			out.append_string(`{"name":"`);
			json_escape_into(&out, clip.name);
			out.appendf(`","duration":%s,"loop":`, (JsonFloat)clip.duration);
			out.append_string(clip.loop ? "true" : "false");
			out.append_string(`,"keyframes":`);
			out.appendf("%d", clip.keyframes.len);
			out.append_char('}');
		}
		out.append_string(`]}`);
	}
	out.append_char(']');

	out.append_string(`,"playback":{"animating":`);
	out.append_string(app.animating ? "true" : "false");
	out.appendf(`,"time":%s,"clip":`, (JsonFloat)app.anim_time);
	AnimTemplate* current = app.clip(app.current_ref);
	if (current != null)
	{
		out.append_string(`{"name":"`);
		json_escape_into(&out, current.name);
		out.appendf(`","pack":%d,"clip":%d,"duration":%s,"loop":`, app.current_ref.pack, app.current_ref.clip, (JsonFloat)current.duration);
		out.append_string(current.loop ? "true" : "false");
		out.append_char('}');
	}
	else
	{
		out.append_string("null");
	}
	// Every loaded character, the one all of the above is about among them.
	out.append_string(`},`);
	append_cast_json(&out, app);
	out.append_char('}');

	return out.copy_str(mem);
}

<*
 save_project: the open document written in place, and a report of what happened.

 `save_session` is the whole of the work — it copies a foreign model once, writes
 the rig into it, and writes the sidecar beside it — and it answers by leaving a
 notice and clearing `authored_dirty`, not by returning. So this reads those back:
 the file now behind the project (`retarget_source` points `source_path` at it on
 success), whether anything remains unsaved, and the notice's own sentence. No
 open project is a refusal in the reply rather than a fault — a missing path is a
 state a caller asks about, not an error in the asking.
*>
fn String save_project_json(AppState* app)
{
	DString out = dstring::new(mem);
	defer out.free();

	if (app.source_path.len == 0)
	{
		out.append_string(`{"saved":null,"authored_dirty":`);
		out.append_string(app.authored_dirty ? "true" : "false");
		out.append_string(`,"note":"there is no open project to save — open a model first. save_pack publishes clips to the library, which needs no project path and is a different thing."}`);
		return out.copy_str(mem);
	}

	app.save_session();

	out.append_string(`{"saved":"`);
	json_escape_into(&out, base_name(app.source_path));
	out.append_string(`","path":"`);
	json_escape_into(&out, app.source_path);
	out.append_string(`","authored_dirty":`);
	out.append_string(app.authored_dirty ? "true" : "false");
	out.append_string(`,"note":"`);
	json_escape_into(&out, app.notice());
	out.append_string(`"}`);
	return out.copy_str(mem);
}

<*
 get_skeleton: the dots and edges as stored, plus the BFS joint order with
 parents and bone directions — the order clips and poses index joints in.

 Three additions appear only where a rig has asked for them, on the rule `reach`
 already follows: a dot's `limits` when it has persistent rotation metadata, a
 top-level `secondary` list of the chains when any bone has secondary motion —
 each in the shape set_secondary_motion takes, so a readback can be handed
 straight back to it — and a top-level `colliders` list when any capsule is
 set. A plain rig reads exactly as it always did — writing nulls on every dot
 would spend a line each saying the ordinary thing.
*>
fn String skeleton_json(AppState* app)
{
	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"root":`);
	out.appendf("%d", app.doc.root_id);
	out.append_string(`,"dots":[`);
	foreach (i, dot : app.doc.dots.array_view())
	{
		if (i > 0) out.append_char(',');
		out.appendf(`{"id":%d,"name":"`, dot.id);
		append_bone_name(&out, dot.id, dot.name);
		out.append_string(`","position":`);
		append_vec3(&out, dot.position);
		// Only for a dot that has one. Reporting "reach":0 on every dot of every
		// rig would spend a line each saying the ordinary thing.
		if (dot.reach > 0.0f) out.appendf(`,"reach":%.6g`, dot.reach);
		if (dot.grow != 0.0f) out.appendf(`,"grow":%.6g`, dot.grow);
		if (dot.band > 0.0f) out.appendf(`,"soft":%.6g`, dot.band);

		append_rotation_limits(&out, app, dot.id);
		out.append_char('}');
	}
	out.append_string(`],"edges":[`);
	foreach (i, edge : app.doc.edges.array_view())
	{
		if (i > 0) out.append_char(',');
		out.appendf("[%d,%d]", edge.a, edge.b);
	}
	out.append_string(`],"joints":`);

	RigView? opened = app.open_rig(mem);
	// No dots: the array the caller was promised, empty. The '[' below is not
	// reached on this path, so it has to be written here as well — a bare ']'
	// here makes the whole answer unparseable, and this is the state crig opens
	// in, so it is the first thing an agent would ask.
	if (catch opened)
	{
		out.append_string(`[],"height":0`);
		append_collider_list(&out, app);
		append_exclusion_list(&out, app);
		out.append_char('}');
		return out.copy_str(mem);
	}
	RigView view = opened;
	defer view.free(mem);

	Vec3[] directions = view.skeleton.bone_directions(mem);
	defer alloc::free(mem, directions);

	out.append_char('[');
	foreach (j, id : view.dot_ids)
	{
		if (j > 0) out.append_char(',');
		out.appendf(`{"dot":%d,"name":"`, id);
		append_bone_name(&out, id, view.names[j]);
		out.appendf(`","parent":%d,"position":`, view.skeleton.parents[j]);
		append_vec3(&out, view.skeleton.joints[j]);
		out.append_string(`,"bone":`);
		append_vec3(&out, directions[j]);
		out.append_char('}');
	}
	out.append_string(`],"height":`);
	out.appendf("%s", (JsonFloat)view.skeleton.height());
	append_rig_issues(&out, app, false);
	append_secondary_list(&out, app, &view);
	append_collider_list(&out, app);
	append_exclusion_list(&out, app);
	out.append_char('}');

	return out.copy_str(mem);
}

<*
 What is wrong with the rig itself, which every clip on it inherits: a knee or
 elbow whose limit table refuses the way it naturally folds. Playback and export
 clamp every keyed bend of such a joint, so no clip edit mends it, and an agent
 that only measures clips reads it as twenty clips' worth of limit faults.

 @param always : `Write an empty list when there is nothing, rather than nothing.`
*>
fn void append_rig_issues(DString* out, AppState* app, bool always) @private
{
	HingeIssue[HINGE_MOST] found;
	usz count = 0;
	RigView? opened = app.open_rig(mem);
	if (try view = opened)
	{
		defer view.free(mem);
		count = hinge_issues(&app.doc, &view.skeleton, view.names, view.dot_ids, found[..]);
	}
	StaleFrame[STALE_FRAME_MOST] stale;
	usz drifted = 0;
	if (try view = app.open_rig(mem))
	{
		defer view.free(mem);
		drifted = stale_limit_frames(&app.doc, &view.skeleton, view.names, view.dot_ids, stale[..]);
	}
	if (count == 0 && drifted == 0 && !always) return;
	out.append_string(`,"rig_issues":[`);
	for (usz i = 0; i < drifted; i++)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"kind":"limits_stale","joint":"`);
		json_escape_into(out, stale[i].joint);
		// The fix carries this joint's own table onto its bone and touches no
		// other: plan_limits would re-plan the whole rig, limits taken off included.
		out.appendf(`","drift":%s,"note":"its limit table is pinned to where the bone pointed before the joint moved, so a natural turn reads partly as locked twist and is held back","fix":{"tool":"edit_rig","args":{"ops":[{"op":"limits","joint":"`,
			(JsonFloat)stale[i].drift);
		json_escape_into(out, stale[i].joint);
		out.append_string(`","bone_axes":true}]}}}`);
	}
	for (usz i = 0; i < count; i++)
	{
		if (i > 0 || drifted > 0) out.append_char(',');
		bool inverted = found[i].kind == INVERTED;
		out.appendf(`{"kind":"%s","joint":"`, inverted ? "limits_inverted" : "limits_blocked");
		json_escape_into(out, found[i].joint);
		out.appendf(`","refused":%s,"note":"%s","fix":{"tool":"edit_rig","args":{"ops":[{"op":"plan_limits"}]}}}`,
			(JsonFloat)found[i].refused,
			inverted ? "its limits let it fold only the wrong way: every clip plays with this joint clamped straight or flipped backward"
				: "its limits keep it from folding either way: every clip plays with this joint held straight");
	}
	out.append_char(']');
}

<*
 A dot's persistent bone-local limit table, in radians, or nothing when that
 joint is unconstrained and has no explicit frame choice.
*>
fn void append_rotation_limits(DString* out, AppState* app, uint dot_id) @private
{
	JointRotationLimits limits = app.doc.rotation_limits_of(dot_id);
	if (!limits.constrained && limits.primary_child == 0 && !limits.has_saved_frame) return;

	out.appendf(`,"limits":{"active":%s`, limits.constrained);
	String[3] names = { "x", "y", "z" };
	foreach (usz a, axis : limits.axes)
	{
		out.appendf(`,"%s":{"allow":%s,"minimum":%s,"maximum":%s,"locked":%s}`,
			names[a], axis.allowed, (JsonFloat)axis.minimum, (JsonFloat)axis.maximum, (JsonFloat)axis.locked);
	}
	Dot* child = app.doc.find(limits.primary_child);
	if (child)
	{
		out.append_string(`,"primary_child":"`);
		append_bone_name(out, child.id, child.name);
		out.append_char('"');
	}
	if (limits.has_saved_frame)
	{
		out.appendf(`,"frame":%s`, (JsonQuat)limits.saved_frame);
	}
	out.append_char('}');
}

<*
 The rig's secondary-motion chains, or nothing at all when it has none: one
 object per chain in set_secondary_motion's own shape, with the joints the run
 resolves to on this build. A chain whose root or tip has since been deleted
 resolves to no joints and is still listed — the record is the document's, and
 undo may bring the dot back under it.
*>
fn void append_secondary_list(DString* out, AppState* app, RigView* view) @private
{
	usz written = 0;
	foreach (chain : app.doc.secondary.array_view())
	{
		if (!app.doc.find(chain.root)) continue;
		out.append_string(written == 0 ? `,"secondary":[` : `,`);
		append_secondary_json(out, app, view, chain);
		written++;
	}
	if (written > 0) out.append_char(']');
}

<*
 The rig's collider capsules, or nothing at all when it has none.

 Top level rather than per dot, like the chains, because that is what a capsule
 is: a shape the *chains* are tested against, not a property of the bone carrying
 it. A belly is a collider and never dynamic.

 Entries whose dot has since been deleted are skipped, the same way
 `jiggle_specs_from_document` skips them: the document keeps them so undo can
 bring them back with the dot, and until it does there is no bone to name.
*>
fn void append_collider_list(DString* out, AppState* app) @private
{
	if (app.doc.colliders.len() == 0) return;

	usz written = 0;
	foreach (entry : app.doc.colliders.array_view())
	{
		if (entry.radius <= 0.0f) continue;
		Dot* dot = app.doc.find(entry.dot_id);
		if (!dot) continue;

		out.append_string(written == 0 ? `,"colliders":[{"joint":"` : `,{"joint":"`);
		append_bone_name(out, dot.id, dot.name);
		out.appendf(`","radius":%.6g}`, entry.radius);
		written++;
	}
	if (written > 0) out.append_char(']');
}

<*
 The region pairs the self-collision check is told to leave alone, by joint
 name, and only when there are any: the exceptional control, absent from an
 ordinary rig's answer for the reason the colliders are.
*>
fn void append_exclusion_list(DString* out, AppState* app) @private
{
	usz written = 0;
	foreach (entry : app.doc.collision_exclusions.array_view())
	{
		Dot* a = app.doc.find(entry.a);
		Dot* b = app.doc.find(entry.b);
		if (!a || !b) continue;

		out.append_string(written == 0 ? `,"exclusions":[{"a":"` : `,{"a":"`);
		append_bone_name(out, a.id, a.name);
		out.append_string(`","b":"`);
		append_bone_name(out, b.id, b.name);
		out.append_string(`"}`);
		written++;
	}
	if (written > 0) out.append_char(']');
}

<*
 get_pose: `clip` sampled at `time` against the live rig — each joint's
 world position and world orientation (quaternion [x,y,z,w]). Computed
 fresh, like AppState.refresh_animation; the live player's pose_palette is
 not consulted, so this answers for any clip at any t, playing or not.

 Faults: RIG_EMPTY on a dotless document, CLIP_NOT_FOUND, CLIP_AMBIGUOUS
 when the name matches clips in more than one pack. Each writes its reason
 into `detail`.
*>
fn String? pose_json(AppState* app, String clip_name, float time, DString* detail)
{
	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string("this document has no dots, so there is no rig to sample a pose against. get_scene reports what is loaded.");
		return RIG_EMPTY~;
	}
	RigView view = opened;
	defer view.free(mem);

	AnimRef ref = resolve_named(app, clip_name, detail)!;
	AnimTemplate* template = app.clip(ref);

	// The pose as it plays: the keys held inside the rig's joint limits, grounded,
	// then pinned and aimed — what the viewport draws and the export writes, not
	// the keys as typed. Where the limits changed a joint, how far is said, since
	// a keyed bend the rig refuses is otherwise invisible in the numbers.
	rig::Pose pose = app.evaluated_clip_pose(mem, &view, *template, ref, time, aimed: true);
	defer pose.free(mem);
	rig::Pose authored = template.pose(mem, &view.skeleton, app.names_for(&view, ref), time, false);
	defer authored.free(mem);
	rig::Pose held = authored.copy(mem);
	defer held.free(mem);
	constrain_pose_to_joint_limits(&app.doc, &view.skeleton, view.dot_ids, &held);

	return joints_json(app, &view, pose, template.name, time, &authored, &held);
}

// Every joint's world position and orientation sampled from the requested clip.
fn String? joints_json(AppState* app, RigView* view, rig::Pose pose, String clip_name, float time,
	rig::Pose* authored = null, rig::Pose* held = null) @private
{
	Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!;
	defer alloc::free(mem, palette);

	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"clip":"`);
	json_escape_into(&out, clip_name);
	out.appendf(`","time":%s,"joints":[`, (JsonFloat)time);
	foreach (j, id : view.dot_ids)
	{
		if (j > 0) out.append_char(',');
		Vec3 world = view.skeleton.joints[j].transform(palette[j]);
		Quaternionf rotation = rig::quat_from_matrix(palette[j]);
		out.append_string(`{"name":"`);
		append_bone_name(&out, id, view.names[j]);
		out.append_string(`","position":`);
		append_vec3(&out, world);
		out.appendf(`,"rotation":%s}`, (JsonQuat)rotation);
	}
	out.append_char(']');
	// The joints whose keyed turn the rig's limits change, and by how much: a knee
	// keyed bent that plays straight shows here and nowhere else.
	if (authored && held)
	{
		out.append_string(`,"limited":[`);
		usz written = 0;
		foreach (j, id : view.dot_ids)
		{
			if (j >= authored.rotations.len || j >= held.rotations.len) break;
			Quaternionf a = authored.rotations[j];
			Quaternionf b = held.rotations[j];
			float dot = math::abs(a.v.x * b.v.x + a.v.y * b.v.y + a.v.z * b.v.z + a.v.w * b.v.w);
			float removed = 2.0f * math::acos(math::min(dot, 1.0f));
			if (removed <= ISSUE_LIMIT_TOLERANCE) continue;
			if (written++ > 0) out.append_char(',');
			out.append_string(`{"name":"`);
			append_bone_name(&out, id, view.names[j]);
			out.appendf(`","removed":%s}`, (JsonFloat)removed);
		}
		out.append_char(']');
	}
	out.append_char('}');
	return out.copy_str(mem);
}

// As many instants as an answer is worth looking at. Well past what any cycle
// needs to be characterised, and short of a payload nobody would read.
const usz MEASURE_SAMPLE_LIMIT @local = 512;

<*
 measure_clip: what the clip does, against the rig on screen.

 The same skeleton and names `pose_json` builds, for the same reason: these are
 measurements of the clip *as it will play here*, carried onto this rig's bones
 and with its ground solve run, not of the keyframes as they were written.

 Per-joint rows are written only for joints the rig can name. An unnamed dot is
 one no clip can address, so reporting how far it travelled would be reporting on
 something nobody asked to move.
*>
fn String? metrics_json(AppState* app, String clip_name, usz samples, DString* detail)
{
	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string("this document has no dots, so there is no rig to measure a clip against. get_scene reports what is loaded.");
		return RIG_EMPTY~;
	}
	RigView view = opened;
	defer view.free(mem);

	AnimRef ref = resolve_named(app, clip_name, detail)!;
	if (!app.ensure_clip_imported(ref))
	{
		detail.append_string("that clip's keys could not be read out of its pack.");
		return CLIP_NOT_FOUND~;
	}
	AnimTemplate* template = app.clip(ref);

	// Zero asks for as many as the clip's length is worth: sixty a second, so a
	// stance window is seen at more than a handful of instants.
	if (samples == 0)
	{
		samples = (usz)math::ceil(template.duration * 60.0f);
		if (samples < 32) samples = 32;
		if (samples > 256) samples = 256;
	}

	// A clip that declares no feet is measured by the ones its motion plants, as
	// the Check panel does — or a hand-keyed walk that skates reports no slide.
	bool owned;
	AnimGround contacts = clip_contacts(&view, view.names, template, &owned);
	defer if (owned) contacts.free(mem);

	// The document and its dot ids go in so limit saturation can be tested against
	// the rotation-limit tables and every instant held inside them, as it plays.
	ClipMetrics numbers = clip_metrics(mem, &view.skeleton, view.names, *template, samples,
		&app.doc, view.dot_ids, owned ? contacts : (AnimGround){});
	defer numbers.free(mem);

	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"clip":"`);
	json_escape_into(&out, template.name);
	out.appendf(`","samples":%d,"grounded":`, numbers.samples);
	out.append_string(template.ground.solves() ? "true" : "false");
	out.appendf(`,"feet":"%s"`, template.ground.solves() ? "declared" : (contacts.feet.len > 0 ? "read_from_motion" : "none"));
	out.appendf(`,"verdict":"%s"`, clip_usable(numbers) ? "usable" : "needs_work");
	// The verdict on the clip alone: a rig fault (of_rig) makes every clip on the
	// rig needs_work until edit_rig mends it, which says nothing about whether
	// this clip's own keys are done.
	out.appendf(`,"clip_verdict":"%s"`, clip_usable(numbers, ignore_rig: true) ? "usable" : "needs_work");
	out.appendf(`,"floor":%s,"floor_penetration":%s,"foot_slide":%s,"ground_speed":%s,"stride":%s,"root_bob":%s`,
		(JsonFloat)numbers.floor, (JsonFloat)numbers.floor_penetration, (JsonFloat)numbers.foot_slide, (JsonFloat)numbers.ground_speed,
		(JsonFloat)numbers.stride, (JsonFloat)numbers.root_bob);
	out.append_string(`,"units":"fractions of rig height; ground_speed is rig heights per second; floor is model space","joints":[`);

	usz written = 0;
	foreach (row : numbers.joints)
	{
		if (row.name.len == 0) continue;
		if (written > 0) out.append_char(',');
		out.append_string(`{"name":"`);
		json_escape_into(&out, row.name);
		out.appendf(`","travel":%s,"low":%s,"high":%s}`, (JsonFloat)row.travel, (JsonFloat)row.low, (JsonFloat)row.high);
		written++;
	}

	// The localized faults, each named to a joint and a phase — where to edit, as
	// against the aggregates above, which say only that there is something to. A
	// limit row carries the bone-local axis it was hit on.
	out.append_string(`],"issues":[`);
	foreach (usz i, issue : numbers.issues)
	{
		if (i > 0) out.append_char(',');
		out.appendf(`{"kind":"%s","joint":"`, issue.kind.tag());
		json_escape_into(&out, issue.joint);
		out.appendf(`","phase":%.6g,"magnitude":%.6g,"unit":"%s"`,
			issue.phase, issue.magnitude, issue_unit(issue.kind));
		if (issue.axis >= 0 && issue.axis < 3)
		{
			out.appendf(`,"axis":"%c"`, "xyz"[(usz)issue.axis]);
		}
		if (issue.key > 0)
		{
			usz k = (usz)(issue.key - 1);
			out.appendf(`,"key":%d,"partial":%s`, k, key_partial(*template, k) ? "true" : "false");
		}
		if (issue.kind.of_rig()) out.append_string(`,"of_rig":true`);
		if (!issue.blocks()) out.append_string(`,"blocks":false`);
		out.append_char('}');
	}
	out.append_char(']');
	if (numbers.rig_omitted > 0) out.appendf(`,"rig_issues_omitted":%d`, numbers.rig_omitted);
	out.append_string(`,"fixes":`);
	append_fixes(&out, *template, numbers);
	out.appendf(`,"tolerances":{"foot_slide":%.6g,"floor_penetration":%.6g,"limit_saturation":%.6g,"loop_position":%.6g,"loop_velocity":%.6g,"pop":%.6g,"root_pop":%.6g,"note":"an issue is reported only past its tolerance; foot_slide/floor_penetration/loop_position/root_pop are fractions of rig height, limit_saturation and pop are radians, loop_velocity is rig heights per second. A pop is a joint turning more than %.6g radians faster than %.6g radians a second, or an instant standing that far off the path its neighbours set within %.6g s — read from a walk of every key and %.6g instants a second, so a snap between the even samples is still seen. Loop faults are measured with the root's horizontal travel removed, so intended locomotion is not flagged; they need a looping clip and at least four samples. Every number is of the clip as it plays and exports: held inside the rig's joint limits, grounded, pinned and aimed; limit_saturation alone reads the keys before the limits hold them. limits_inverted and limits_blocked are faults of the rig, not the clip: every clip on it plays wrong until they are mended. An issue marked blocks:false is reported and does not make the verdict needs_work: a note, or a limit overshoot — what the limits hold is what plays and is what every other number measures; the overshoot says the keys ask for more than the rig allows, and past %.6g radians a fix is offered."}`,
		ISSUE_SLIDE_TOLERANCE, ISSUE_PENETRATION_TOLERANCE, ISSUE_LIMIT_TOLERANCE,
		ISSUE_LOOP_POSITION_TOLERANCE, ISSUE_LOOP_VELOCITY_TOLERANCE, ISSUE_POP_TOLERANCE, ROOT_POP_STEP,
		POP_STEP, POP_SPEED, POP_WINDOW, MOTION_RATE, ISSUE_LIMIT_NOTABLE);
	out.append_char('}');
	return out.copy_str(mem);
}

// The unit each localized magnitude is in, for the reader that takes one issue
// out of context.
fn String issue_unit(ClipIssueKind kind) @private
{
	switch (kind)
	{
		case LIMIT_SATURATION:
		case POP:
		case LIMITS_INVERTED:
		case LIMITS_BLOCKED:
		case LIMITS_STALE:
			return "radians";
		case LOOP_VELOCITY: return "heights_per_second";
		case AIM_STARE: return "influence";
		default: return "height";
	}
}

// Whether a clip is fit to ship: nothing found but notes. With ignore_rig, the
// rig's own faults are left out, which is the verdict on the clip's keys alone.
fn bool clip_usable(ClipMetrics numbers, bool ignore_rig = false) @private
{
	foreach (issue : numbers.issues)
	{
		if (ignore_rig && issue.kind.of_rig()) continue;
		if (issue.blocks()) return false;
	}
	return true;
}

// Whether keyframe `k` keys fewer joints than the clip's fullest key does — the
// shape a leftover correction key has, sitting between whole poses.
fn bool key_partial(AnimTemplate clip, usz k) @private
{
	if (k >= clip.keyframes.len) return false;
	usz fullest = 0;
	foreach (frame : clip.keyframes) if (frame.dots.len > fullest) fullest = frame.dots.len;
	return clip.keyframes[k].dots.len < fullest;
}

<*
 One call per kind of fault found, with the arguments filled in: what an agent
 reading the issues would otherwise have to work out from the docs, and what it
 has been seen to get wrong — reading a rig's inverted knees as a clip to repair.

 Rig faults lead, since no clip edit mends them and every other number on the
 rig is measured through them.
*>
fn void append_fixes(DString* out, AnimTemplate clip, ClipMetrics numbers) @private
{
	out.append_char('[');
	usz written = 0;

	// What each kind was found to need; each is written once.
	bool inverted;
	bool blocked;
	bool slide;
	bool sink;
	bool saturated;
	bool seam;
	bool seam_speed;
	String seam_joint;
	bool root_pop;
	bool stare;
	List{usz} pop_keys;
	pop_keys.init(mem);
	defer pop_keys.free();
	List{String} smooth_joints;
	smooth_joints.init(mem);
	defer smooth_joints.free();
	String blocked_joint;
	String saturated_joint;
	List{String} stale_joints;
	stale_joints.init(mem);
	defer stale_joints.free();
	foreach (issue : numbers.issues)
	{
		switch (issue.kind)
		{
			case LIMITS_INVERTED:
				inverted = true;
			case LIMITS_STALE:
				if (issue.joint.len > 0) stale_joints.push(issue.joint);
			case LIMITS_BLOCKED:
				blocked = true;
				blocked_joint = issue.joint;
			case FOOT_SLIDE: slide = true;
			case FLOOR_PENETRATION: sink = true;
			case LIMIT_SATURATION:
				if (issue.magnitude <= ISSUE_LIMIT_NOTABLE) break;
				saturated = true;
				saturated_joint = issue.joint;
			case LOOP_POSITION: seam = true;
			case LOOP_VELOCITY:
				seam_speed = true;
				seam_joint = issue.joint;
			case ROOT_POP:
				if (issue.key > 0 && key_partial(clip, (usz)(issue.key - 1)))
				{
					add_key(&pop_keys, (usz)(issue.key - 1));
				}
				else
				{
					root_pop = true;
				}
			case AIM_STARE: stare = true;
			case POP:
				// A snap at the seam of a loop is the cycle not running into its
				// own start, whichever key sits there: cut the cycle again.
				if (clip.loop && (issue.phase < 0.01f || issue.phase > 0.99f))
				{
					seam = true;
				}
				else if (issue.key > 0 && key_partial(clip, (usz)(issue.key - 1)))
				{
					add_key(&pop_keys, (usz)(issue.key - 1));
				}
				else if (issue.joint.len > 0)
				{
					smooth_joints.push(issue.joint);
				}
		}
	}

	if (inverted)
	{
		fix_open(out, &written, "limits_inverted", "edit_rig");
		out.append_string(`{"ops":[{"op":"plan_limits"}]},"why":"the rig's limit tables hold natural motion back — a knee or elbow allowed to fold only the wrong way — so playback and export clamp it; put the body plan's limits back and carry every table onto its bone, then measure again"}`);
	}
	if (stale_joints.len() > 0)
	{
		// One limits op per joint, carrying its own table onto its bone: the rows
		// the person set are kept, and no other joint's table is touched — where
		// plan_limits would re-plan the whole rig, limits taken off included.
		fix_open(out, &written, "limits_stale", "edit_rig");
		out.append_string(`{"ops":[`);
		foreach (usz i, joint : stale_joints)
		{
			if (i > 0) out.append_char(',');
			out.append_string(`{"op":"limits","joint":"`);
			json_escape_into(out, joint);
			out.append_string(`","bone_axes":true}`);
		}
		out.append_string(`]},"why":"these limit tables are pinned to where their bones pointed before the joints moved, so a natural turn reads partly as locked twist and is held back; carry each onto its bone, keeping its rows, and leave every other joint's table as it is"}`);
	}
	if (blocked)
	{
		fix_open(out, &written, "limits_blocked", "edit_rig");
		out.append_string(`{"ops":[{"op":"plan_limits"}]},"why":"the limit table keeps `);
		json_escape_into(out, blocked_joint);
		out.append_string(` from folding either way; put the body plan's limits back, or widen it with an edit_rig limits op"}`);
	}
	if (pop_keys.len() > 0)
	{
		fix_open(out, &written, "pop", "remove_keys");
		out.append_string(`{"clip":"`);
		json_escape_into(out, clip.name);
		out.append_string(`","keys":[`);
		foreach (usz i, k : pop_keys)
		{
			if (i > 0) out.append_char(',');
			out.appendf("%d", k);
		}
		out.append_string(`]},"why":"these keys name only a few joints and jut out of the whole poses either side of them; removing them lets the motion run through"}`);
	}
	if (smooth_joints.len() > 0)
	{
		fix_open(out, &written, "pop", "smooth_clip");
		out.append_string(`{"clip":"`);
		json_escape_into(out, clip.name);
		out.append_string(`","window":0.1,"joints":[`);
		foreach (usz i, joint : smooth_joints)
		{
			if (i > 0) out.append_char(',');
			out.append_char('"');
			json_escape_into(out, joint);
			out.append_char('"');
		}
		out.append_string(`]},"why":"the joints snap; get_clip around the issue's phase shows the key that jumps — fix its value, or smooth across it. A pop under a limit_saturation on the same joint is the limit clamp flipping, which mending the limits or the pose takes away"}`);
	}
	if (seam)
	{
		fix_open(out, &written, "loop", "make_loop");
		out.append_string(`{"clip":"`);
		json_escape_into(out, clip.name);
		out.append_string(`"},"why":"the cycle does not run into its own start; make_loop cuts a seamless cycle out of the take (give period as the range one cycle may last), close_loop restates the first pose at the end when the last stretch already leads into it"}`);
	}
	else if (seam_speed)
	{
		fix_open(out, &written, "loop", "smooth_clip");
		out.append_string(`{"clip":"`);
		json_escape_into(out, clip.name);
		out.append_string(`","window":0.1,"joints":["`);
		json_escape_into(out, seam_joint);
		out.append_string(`"]},"why":"the cycle meets its start in the right pose at the wrong speed; smoothing wraps round a loop's seam and evens the speed through it"}`);
	}
	if (slide)
	{
		fix_open(out, &written, "foot_slide", "pin_feet");
		out.append_string(`{"clip":"`);
		json_escape_into(out, clip.name);
		out.append_string(`","travel":"auto"},"why":"planted feet skate; pin them to the floor across every window they are down"}`);
	}
	if (root_pop)
	{
		fix_open(out, &written, "root_pop", "get_clip");
		out.append_string(`{"clip":"`);
		json_escape_into(out, clip.name);
		out.append_string(`"},"why":"the floor solve lifts or drops the body at once where the planted feet change; give every foot a ground window that overlaps the next foot's, or pin_feet the clip"}`);
	}
	if (sink)
	{
		fix_open(out, &written, "floor_penetration", "patch_clip");
		out.append_string(`{"clip":"`);
		json_escape_into(out, clip.name);
		out.append_string(`"},"why":"a joint goes through the floor; a ground spec (apply_clip ground) puts the planted feet on it, or patch_clip with a range lifts the hips there"}`);
	}
	if (saturated && !inverted && !blocked)
	{
		fix_open(out, &written, "limit_saturation", "patch_clip");
		out.append_string(`{"clip":"`);
		json_escape_into(out, clip.name);
		out.append_string(`","joints":[{"name":"`);
		json_escape_into(out, saturated_joint);
		out.append_string(`"}]},"why":"the keys turn a joint past its limits and playback holds it at the edge, so what plays is not what was keyed; bring the pose back inside, or if every natural clip saturates the same hinge, edit_rig plan_limits"}`);
	}
	if (stare)
	{
		fix_open(out, &written, "aim_stare", "set_aim");
		out.append_string(`{"remove":true},"why":"a look-at locked on one still point freezes the head while the body moves; fine for a figure watching something, wrong for locomotion — remove it or key the target to move"}`);
	}
	out.append_char(']');
}

fn void add_key(List{usz}* keys, usz k) @private
{
	foreach (have : *keys) if (have == k) return;
	keys.push(k);
}

fn void fix_open(DString* out, usz* written, String issue, String tool) @private
{
	if (*written > 0) out.append_char(',');
	*written += 1;
	out.appendf(`{"issue":"%s","tool":"%s","args":`, issue, tool);
}

// What `delete_clip` answers with: what went, and what is left to go.
fn String deleted_json(AppState* app, String name)
{
	DString out = dstring::new(mem);
	defer out.free();

	AnimPack* pack = app.authored();

	out.append_string(`{"deleted":"`);
	json_escape_into(&out, name);
	out.appendf(`","remaining":%d,"clips":[`, pack ? pack.clips.len : 0);
	if (pack)
	{
		foreach (usz i, held : pack.clips)
		{
			if (i > 0) out.append_char(',');
			out.append_char('"');
			json_escape_into(&out, held.name);
			out.append_char('"');
		}
	}
	out.append_string(`],"playing":`);
	out.append_string(app.animating ? "true" : "false");
	out.append_char('}');

	return out.copy_str(mem);
}

// ---------------------------------------------------------------------------
// Three appenders every payload in the module uses, kept here because they are
// the JSON spelling of three of crig's own types and belong to none of the tools
// in particular.

fn void append_vec3(DString* out, Vec3 v) @private => out.appendf("%s", (JsonVec3)v);

// Unnamed dots still need an address: clips call them bone_<id>. This one is
// for inside a JSON string; `append_bone_label` is the same name for prose, which
// is escaped once, whole, when the message is written.
fn void append_bone_name(DString* out, uint id, String name) @private
{
	if (name.len > 0)
	{
		json_escape_into(out, name);
	}
	else
	{
		out.appendf("bone_%d", id);
	}
}

fn void append_bone_label(DString* out, uint id, String name) @private
{
	if (name.len > 0)
	{
		out.append_string(name);
	}
	else
	{
		out.appendf("bone_%d", id);
	}
}
