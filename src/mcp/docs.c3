<*
 get_api_docs: the conventions, a section at a time, and the tool reference.

 Two things live here, and they used to be one. The **conventions** are prose
 that no schema has room for — what an angle is measured in, why a walk cycle
 must not key the root's height, which axes a rotation is about once the chain
 above the joint has turned. The **tool reference** is each tool's own
 description and JSON Schema, and that is not prose kept here at all: it is read
 off the `ToolDef` the wire validates against, by `append_tool_help` below.

 That second part is the change. This document used to carry a hand-written
 summary of all twenty-seven tools — seven and a half thousand characters
 restating, a little less precisely, what the registrations already said. Two
 copies of one fact drift apart, and the copy an agent reads was the one with no
 compiler behind it. So the summaries are gone and `{"tool":"apply_clip"}` answers
 from the registry, which makes this file the conventions and a renderer.

 **Sectioned, because the whole of it was twenty thousand characters.** A caller
 that needs to know how a ground spec works should not be handed the physics
 solver's five constants to find out. No arguments gives an index — a line per
 section and every tool's name, 2.8k — and one section is pulled by name, about
 0.7k. `"all"` is still there for a caller that wants the lot, now 12.5k, and is
 what the `crig://api-docs` resource serves.

 The listed description names every section, deliberately: it is the one
 piece of this that a client keeps in front of the model anyway, and naming them
 there is what makes the common case one call rather than an index followed by a
 second.

 The prose is stored unescaped and goes out through `append_json_string`. A
 sentence that wants a quotation mark in it should be able to have one without
 that being a decision about JSON.
*>
module crig;

import std::collections::object;

faultdef DOCS_BAD_ARGS;

const String API_DOCS_URI = "crig://api-docs";

<*
 Bumped whenever anything here changes meaning.

 An agent works from what it remembers of a surface as much as from what it
 fetches, and this is the one number that tells it the two have diverged.
*>
const int API_DOCS_VERSION = 42;

// Always in the index, because everything else assumes them and both are one
// line. `units` is JSON rather than prose — it is a table, and reading it as a
// sentence is work a caller should not have to do.
const String DOCS_SPACE = "glTF: +Y up, the model faces +Z; positions are unnormalised model space";
const String DOCS_UNITS = `{"time":"seconds","angle":"radians","rotation":"quaternion [x,y,z,w]","move":"fraction of rig height"}`;

<*
 One section of the conventions.

 `hook` is what the index carries: a line saying what the section answers, so
 that picking one is a decision a caller can make without reading all of them.
 It is not a summary — a hook that tried to be one would be the duplication this
 file just got rid of, in miniature.
*>
struct DocTopic
{
	String name;
	String hook;
	String text;
}

<*
 The conventions. Order is the order the index reports and the order `"all"`
 writes them in: what a clip is, then how to write one, then how to look at what
 you wrote, then the rig underneath it.
*>
const DocTopic[*] DOC_TOPICS = {
	{
		.name = "clips",
		.hook = "How a keyframe addresses a joint, and how a clip name is looked up.",
		.text = `Rotation and translation are independent tracks per joint. An entry may key either or both; an omitted joint or channel has no key at that time, so its value is sampled between that channel's own surrounding keys and unrelated keyframes do not interrupt it. Explicit identity rotation or zero movement is therefore a real key, not the same as omission. Unnamed dots are addressed as bone_<id> for reading, but only named dots can be animated. A bare clip name is looked for across every pack and ranked: the clip bound to the character first, then the Authored pack, then a pack whose clip fits the rig, then the rest; only a tie at the best rank is an error. "Pack/Clip" says which pack outright, dividing at the last slash.`,
	},
	{
		.name = "authoring",
		.hook = "Where apply_clip writes, and what it takes to make that survive a restart.",
		.text = `apply_clip writes into the project's Authored pack and binds the clip into the timeline, so it is a first-class editable clip: it appears in the clip chooser and the Animations list, becomes the selected clip, and the transport's Play/Pause controls it — a played clip holds its frame when paused rather than snapping back to whatever the timeline last held. save_project persists its authored keys and grounding settings in the model's .crig.json sidecar, which is the same in-place save Ctrl+S makes; get_scene reports authored_dirty so you can tell a save is owed. save_pack is the other kind of save and does not stand in for it: it publishes a reusable library file without consuming the project's editable copies or changing their bindings. With both copies loaded, use Pack/Clip to disambiguate their names. Euler angles are turned about the X, then Y, then Z axes of whichever frame the entry's space names; a rotation about a limb's own bone is not what an euler triple gives, so prefer an explicit axis and angle when the axis matters. Taking a clip off the character again is unbind_clip, one undo step: the clip stays in its pack or file and only stops being one of the character's bound animations, so the next Save no longer writes it into the model. delete_model_clip goes further for the loaded model's own clips: it unbinds the clip and re-saves the model without it, so the animation leaves the glb for good (refused when no model is open, the document has no mesh to re-save, or the clip is not one the loaded file holds; it cannot be undone with undo). delete_clip removes an authored clip, and neither of these deletes a library file.`,
	},
	{
		.name = "turning",
		.hook = "Which axes a rotation is about, local against world, and the sign of every limb.",
		.text = `A rotation is about an axis through the joint, and the model faces +Z. Which axes those are is what a keyframe entry's space decides. With the default, local, they are the parent's as this clip has already turned it — so a joint's axis moves as the joints above it move, and coincides with the model's own only while nothing above the joint is turned. That is the trap on any rig posed away from the pose it rests in: once a shoulder has rolled an arm down, the elbow's hinge is no longer the world X it was in the T-pose. With world, the entry states where the joint points against the model's axes whatever the chain above is doing, and Rigsmith converts. Signs, on a limb hanging downward: positive X swings its far end toward -Z, so thigh and shoulder positive is backward, a knee bends positive only, an elbow negative only, positive ankle points the toes down, positive spine leans the torso forward.`,
	},
	{
		.name = "targets",
		.hook = "Placing a hand or foot by a point instead of by angle, and how to bake it.",
		.text = `solve_targets places an effector — a hand, a foot — at a point by bending the run of joints above it (wrist through elbow through shoulder, ankle through knee through thigh) with the same limit-aware IK a pinned foot is held by, so a reach never lands a joint out of its range. It is for the part of authoring no schema helps with: the shoulder and elbow angles that put a hand where it was wanted, without composing them by hand. A position is [x,y,z] in the model space get_skeleton and get_pose report, or an offset from another joint's place with relative_to — hands ahead of the knees is relative_to a knee. An orientation holds the effector flat once it is placed, a palm down or a foot on the floor, and is a world quaternion in the [x,y,z,w] form get_pose reports. Solve from the rest pose, or from a clip at a time with from, to refine a pose it already has. The answer is a residual per target — how far the joint still is from its point, as a fraction of rig height, reached true when it is within tolerance — and a keyframe in exactly apply_clip's shape. solve_targets writes nothing and spends no undo step: apply_clip with that keyframe bakes it to ordinary editable keys, the same read-then-write round trip get_clip and apply_clip are, so a caller can read the residuals and nudge a target before committing. An effector with no unbranched run above it — a root, or a joint whose parent forks, like the hips — cannot be placed this way and comes back reached false. Which way a two-bone limb bends is a pole: give a target a pole point and the elbow or knee is turned to point at it after the reach, about the root-to-effector line the reach settled, so the effector stays put (unless a joint limit clamps the twist) — point a knee ahead, an elbow back. A pole is ignored where there is no bend to aim — a one-bone limb, a target the limb reaches straight, or a pole on the root-to-effector line itself — and pole_aimed with pole_note on each target report when a pole was aimed, clamped by a limit, or ignored and why. Solving position and orientation together — a wrist that must reach and twist against its limits at once — is still a later increment; orientation is held after the reach, right for a flat foot and a palm. To place a target over time instead of once, give solve_targets a bake argument and a path for position — see the gaits topic.`,
	},
	{
		.name = "editing",
		.hook = "Offsetting a few joints of a clip over a range, without rewriting the rest.",
		.text = `apply_clip writes a whole clip; patch_clip changes part of one. To move a hand a little in an otherwise-right clip, apply_clip would have you send every track back unchanged, and one dropped track is a silent regression — so patch_clip offsets only the joints named and leaves every other track, every other channel, the interpolation and the grounding exactly as they were. An offset is additive: a rotation turns the joint further from where the clip already had it, a move slides it further, composed onto the value the clip holds rather than replacing it. Omit range for a uniform offset across the whole clip; give a sub-range as {"phase":[a,b]} (fractions of the cycle) or {"time":[a,b]} (seconds) to hold the offset at full value from start to end, eased in and out through the clip's own interpolation in the gaps just outside — nothing beyond the range moves, and a joint sparse inside it still gets the edit because the two edges are keyed. space is the same choice a keyframe entry draws in apply_clip: local, the joint's parent frame, is the default and needs no rig; world states the offset against the model's own axes whatever the joints above are doing and reads the rig to convert, which is what "tilt the forearm down" wants when the shoulder is already rolled — see the turning topic. The patch lands in the authored pack as one undo step. It does not retime, invent a key in a channel the joint does not drive, or touch the ground spec; planting a foot is plant_feet, and reshaping the whole cycle is apply_clip.`,
	},
	{
		.name = "playback",
		.hook = "play is for the person at the screen; get_pose is for the caller.",
		.text = `play starts a clip in Rigsmith's own player, which is what the person at the screen is watching, and stop puts the mesh back at rest. Playing is for them, not for the caller: reading a clip back is get_pose, which answers for any clip at any time whether or not anything is playing. One clip plays at a time, and starting another replaces it.`,
	},
	{
		.name = "cycles",
		.hook = "Phase against seconds, and what blend smooth changes about a keyframe.",
		.text = `A clip's phase is t / duration, 0 to 1, and that is what a ground spec's contact windows and a mirror's lag are stated in — never seconds, so retiming a clip carries its footfalls with it. Each joint channel follows its own key times. Its outgoing key may use hold, linear or auto interpolation; omission inherits the clip blend. Hold changes exactly at the next key. Auto fits a cubic through that track's values and, on a looping clip, through the loop point, so an eight-key cycle needs no ninth key restating the first — though one that states it is recognised and not counted twice.`,
	},
	{
		.name = "ground",
		.hook = "Why a clip must key no root height of its own, and what measure_clip checks.",
		.text = `A clip says which joints touch the floor and when; Rigsmith solves the root's height for it, per frame, against the rig actually loaded. That is the one part of a cycle that cannot be authored portably — where the hips sit for the stance foot to reach the ground is a fact about thigh and shin length, so a keyframe stating it has stated it for one skeleton. Write no root Y of your own: the solve supplies stance height and an authored root slide adds on top of it, which is where a flight arc goes. measure_clip is how to check the result: foot_slide and floor_penetration are what separate walking from skating, and neither is visible in a screenshot. It answers with aggregates and with a localized issues list beside them — each fault named to a joint and a phase, so the number that says a cycle is wrong also says where to edit: a foot's worst slide, the joint sunk deepest, each axis an animated rotation runs past its limit, and a looping clip's worst position or velocity break at the seam (with the root's intended travel removed, so a travelling cycle is not flagged for travelling). Each issue states its unit and a tolerances block states what each had to clear. That height solve is only the vertical half. The horizontal half — a stance foot holding its place while the pelvis moves over it, rather than skating sideways with the leg — needs the leg to bend, which the root cannot do, so plant_feet bakes it: it holds each foot across the window it is down with the same IK, keys the corrected leg, and lands it, which is what drives foot_slide down. Its travel argument is the gait speed an in-place cycle is not actually moving at, so a stance foot creeps backward by it — a treadmill; zero, the default, is a foot fixed in the world, right for a clip that travels and for any plain no-skate plant.`,
	},
	{
		.name = "gaits",
		.hook = "Walk, trot and gallop from the rig's own legs, and baking a target path over time.",
		.text = `author_gait writes a locomotion cycle without any angle being guessed. Name a gait (walk, trot, pace, gallop, or custom with each foot's offset) and a duration; it finds the feet — each left/right pair of limbs near the floor that ends in a toe, the lowest joint whose child is a toe being the one the floor meets — or takes them from feet, draws each foot's path (stance slides back along the floor at a constant speed, swing carries it forward through a lifted arc, every foot a fixed share of the cycle behind the next) and solves each leg onto it. A leg is the two to four bones from the first joint below a fork down to the foot; it is solved in the plane the rest leg bends in, so a splayed leg works, the knee bends the side it already rests on, and a leg of three or four bones holds its metatarsal or foot at a preferred tilt and tilts it only as far as the reach needs, where a two-bone leg is plain two-bone IK. The clip lands in the authored pack as dense linear keys (samples a cycle, default 40), one undo step, with a ground spec saying when each foot is down and no root keyed: the floor solve supplies the pelvis height, and a straight-legged figure is solved for a hip a little lower (pelvis_drop) so it never walks on locked knees. The figure does not travel. ground_speed, in model units a second, is the treadmill its stance feet run at, so it is also how fast to move the character through the world; travel is the same as a plant_feet argument. The answer carries measure_clip's numbers for the clip, so foot_slide and floor_penetration are known at once. duty, stride (model units) and lift (a fraction of the leg) override the gait's own. Baking a path is the same idea for one limb: solve_targets with bake {clip, duration, loop, samples, path} takes targets whose position is a path, [{time, position}], and solves every target at each sample instant from the previous instant's pose, so a foot following a path stays in one solution, then writes the keys as one clip in one undo step. path is linear or smooth between keys, a looping clip carries its paths round from the last key to the first, and the answer gives the worst residual each target had over the clip. A three-bone run whose last bone is short against the two above it (a hock and a paw) gets the leg rule in solve_targets too, so it reaches with the knee and keeps the paw's tilt rather than swinging it about.`,
	},
	{
		.name = "looking",
		.hook = "screenshot, render and set_camera, and the question no picture answers.",
		.text = `Three tools answer with a picture and they are not interchangeable. screenshot is the window as it stands, which is the one to reach for when the question is about the interface — a panel over the viewport, a gizmo at the wrong depth. render poses a clip at instants of its own choosing, from a camera of its own choosing, and puts both back: a contact sheet of four to nine moments over a cycle, from the left, is how a gait is read. set_camera moves the camera and leaves it, for the person watching. None of them answers a question with a number in it — a foot sliding four centimetres under a leg that looks planted is invisible in every one of them and is what measure_clip is for.`,
	},
	{
		.name = "rigging",
		.hook = "apply_plan, edit_rig and build_body, and what a body plan holds back.",
		.text = `apply_plan fits a body plan onto the loaded mesh and is usually the first call, because a clip addresses joints by name and an unrigged mesh has none. edit_rig changes the rig afterwards: a list of ops applied as one undo step, and an op that fails takes the whole call back. Its limits op edits persistent bone-local X/Y/Z rotation limits in radians: an allowed axis stays between minimum and maximum, a disallowed one stays at locked, and reset removes the table so the joint is entirely free. A branch needs primary_child or an explicit rest/model-space frame quaternion before those axes are meaningful; get_skeleton reads the complete table back. Limits are rig metadata, not animation keys, and so are collision exclusions: exclude tells the self-collision check never to test two joints' skin regions against each other and include puts them back, for a cape meant to hang through the arm it is skinned beside — an ordinary rig needs none, since one region, regions one bone apart and contacts modelled into the rest pose are already left alone, and get_skeleton lists whatever was excluded. undo and redo step the same history the viewport writes, so a step may take back an edit made here or one the user made by hand. Positions are model space, the space get_skeleton reports; placed and moved dots are pulled inside the mesh unless snap is false. The M-key mirror reflects a joint onto its named twin across the body's symmetry plane, and finds that plane on its own from the rig: its position from the centre joints — the ones whose names carry no side, which sit on the midline whatever the mesh is shaped like — and its orientation from the paired joints' average left-to-right axis. So a lopsided mesh (a tail, a wing, an off-centre export) no longer throws the position off, and a character modelled turned about the vertical — its shoulders and hips at different depths — mirrors across the tilted plane its own joints describe rather than straight across world X (which for a turned rig throws a twin out in front). A near-square rig stays exactly world-aligned, so nothing changes for a forward-facing one. The stored plane, reported by get_scene as symmetry_x, is only the world-aligned fallback (defaulting to the mesh's bounding-box centre) for a rig with no joints to read a plane from. The symmetry op sets that stored fallback: a "plane" number sets it outright, "from":"skeleton" derives it from the centre joints, "from":"mesh" resets it to the box centre. build_body goes the other way, generating a mesh around a rig that is already placed — which is how a rig gets a body it is allowed to ship, and how save_pack gets something to write as a body plan. What a plan places is not the whole of what it carries: joints save_pack was told are optional are held back, because nothing about a model's proportions says where a knuckle goes, and a plan that names none places every joint it has onto every model it is ever fitted to.`,
	},
	{
		.name = "scripting",
		.hook = "Why most tools are not in tools/list, and how a script reaches them.",
		.text = `Only a few of Rigsmith's tools are in tools/list — get_scene, get_crig_docs, solve_targets, undo and redo — beside three's own run_script, screenshot and get_api_docs. Every other tool is registered and dispatched exactly the same way, by the same name, on the same wire; it is hidden, not removed. The reason is what a surface costs when nobody uses it: twenty-six descriptions and their schemas are some thirty-five thousand characters that a client keeps in front of the model for a whole session whether or not the session rigs anything, and most of these tools are loops rather than decisions — edit_rig places sixty-five dots, apply_clip composes a hundred and fifty orientations, paint_weights is measure-adjust-measure. A loop is cheaper written once as JavaScript than emitted call by call. So a client that already knows a name simply calls it, and a client that wants the loop writes a script. Inside three's run_script every tool in this table is crig.ops.<camelCase of its name>, taking objects and answering objects — no JSON.stringify: crig.ops.applyPlan("biped"), crig.ops.editRig([{op:"place",...}]), crig.ops.getSkeleton(), crig.ops.getPose("walk",{t:0.5}), crig.ops.applyClip(spec), crig.ops.measureClip("walk"), crig.ops.paintWeights(spec), crig.ops.play("walk"), crig.ops.savePack("Walks"). The same script reaches three's own API, which is the reason to write one rather than to send calls. Arguments come from the registry rather than from prose: crig.help() names every tool here, crig.help("apply_clip") returns that tool's own description and JSON Schema, and get_crig_docs with a tool argument is the same answer from the wire for a caller that would rather not write a script to ask. crig.call(name, args) reaches anything the prelude has no wrapper for. A refused call throws an Error carrying the tool's own refusal sentence, so try/catch reads exactly what the wire would have said. Two things to know before the first script: each ops call is its own undo entry, so a script is not yet one Ctrl+Z; and undo and redo are refused from inside one — they step a cursor the calls around them recorded against — which is why they stay on the wire. crig.data, the document as live objects with writable dot properties and typed-array views over the mesh, is not installed under three yet; a script that reaches for it gets undefined, and the reads it replaced are crig.ops.getSkeleton and crig.ops.getScene.`,
	},
	{
		.name = "weights",
		.hook = "Weights are derived; corrections ride on top; a pin is the last word.",
		.text = `Weights are derived, not authored: every rig edit rebinds them from scratch, so a rig is its dots and nothing else. Hand corrections ride on top as multipliers rather than replacing that — paint_weights sets what share of a vertex a dot should hold and solves for the correction that lands it, and because it is a ratio over whatever the binder currently says, moving a dot afterwards re-derives the mesh underneath with the correction still on it. A dot owns a vertex when no other dot holds it more strongly, and reaches it when it holds any usable share; ownership is exclusive, reach is not, and where two dots reach far into each other the mesh between them stretches when they disagree. get_weights measures that overlap, show_weights paints it. A joint holds the bone below it — the thigh answers to the hip, the shin to the knee — and a leaf holds half a bone past its own tip. Three things change a bind without moving a dot: edit_rig's reach ends how far one carries, its attach makes a whole piece of the mesh ride one dot rigidly, and its sharpness raises every weight to a power — one number for the model, above 1 narrowing every transition band at once, which is the answer to a body assembled from solid pieces rather than sculpted as one skin. Reach for those before moving a joint off the anatomy to fight the falloff. Above all of it sits one layer that does not ride the binder at all: pin_weights states a vertex's share outright, applied last, so it is the answer where a correction provably cannot reach — the binder gives a dot nothing there and no multiplier lifts a zero. The price is that a pin is absolute and does not re-derive when the dot moves, which is why it is the last thing to reach for and not the first.`,
	},
	{
		.name = "physics",
		.hook = "Secondary motion on chains, what the values mean, and why the bake is not optional.",
		.text = `Secondary motion — a tail, an ear, a braid — is simulated rather than keyed, and the setting lives on the rig, not on a clip: set_secondary_motion gives a chain of bones secondary motion once and it then swings under everything that plays. A chain is a root dot and a tip dot below it on one line of bones; name only the root and the run below it is followed through every joint with exactly one child, so a tail needs one entry. At a fork, name the tip you mean. The root's position stays the animation's and its rotation is simulated, so the skeleton's own root cannot start a chain. How a chain moves is a preset — hair, tail (the default), ear or soft — that starts four values you may then state: flexibility from 0 (follows the clip exactly) to 1 (a rope), damping from 0 (rings for ever) to 1 (a dead stop), gravity as a multiplier on earth's, and collide, whether the chain is pushed out of the character. The character is its own deformed skin, with the chain's triangles left out of it, and the chain is held off by its own thickness as measured from its skin weights plus the collision clearance — nothing to type. Where a chain may swing is its joints' rotation limits, the same tables edit_rig's limits op writes and playback obeys: a joint with none swings freely, a joint with a table stops where the table says, every substep. Colliders are extra capsules swept along a bone, for a rig with no mesh bound or a KHR runtime, which is where they are written. The workflow is four calls: set_secondary_motion to describe the chains, play to watch them (its sim flag turns the solver off for a side-by-side), bake_physics to record one clip's worth of the simulation as ordinary keyframes, then save_pack or an export to ship it. That third call is not optional bookkeeping. Physics runs only while the player is running, so render and screenshot show the keyed pose with no jiggle in it whatever the rig says, and a saved pack or an exported glTF carries no solver — only a baked clip shows secondary motion in a picture or in another program. get_skeleton reads the setup back: a secondary list of the chains in the same shape set_secondary_motion takes, and the capsules as a colliders list beside the joints.`,
	},
	{
		.name = "review",
		.hook = "Saved poses, sketches, and how the person points at them.",
		.text = `The person steers the animation from inside Rigsmith, and this is how it reaches you. Saved poses are the project's pose library, the list in Rigsmith's Pose tab: the person poses the character, saves it under a name, and then asks for it by name — "animate between walk-start and walk-end". get_scene's saved_poses names them; list_poses names them with how many joints each holds, and get_saved_pose reads one in the joint shape apply_clip takes. Use those values as the reference, rather than guessing the pose from its name. save_pose captures the pose a clip has at a time (name, clip, t, optionally joints), and delete_pose removes one; each is one undo step. tween_poses writes a clip from one saved pose to another (duration, back for there-and-back, loop, blend), the starting point for 'animate between these two poses'; refine it with patch_clip or apply_clip (several saved poses become keys of one clip), then measure_clip. get_annotations returns what they sketched on the viewport (the Sketch tool, the pencil in the viewport's tool column): red marks a fault, green a keeper, blue a note, each with the clip and time on screen and the joints it passes near, and screenshot shows the marks painted over the model.`,
	},
	{
		.name = "layers",
		.hook = "Adjustments stacked over a clip: keyed deltas and generators, and where they live.",
		.text = `A clip is its base keys plus an ordered stack of layers, applied bottom to top (index 0 first). A layer has a name, a weight from 0 to 1, mute, solo, an optional time range (start and end seconds) with fade_in and fade_out, a mask of joint names (each entry includes the joints below it; empty is the whole body) and a mode. Additive adds on top of what is underneath: a keyed additive layer holds deltas from rest — identity and zero mean no change — so one breath layer rides on any walk; per joint the turn becomes turn * slerp(identity, delta, weight) and the slide grows by weight * delta. Override blends what is underneath toward the layer, only on the channels the layer keys or drives. The content is keyed — sparse keys in apply_clip's own keyframe shape — or a generator: wave (a sine down the chain from joint to tip, or down every single-child run if no tip, with axis, amplitude in radians, cycles per clip duration, lag as the fraction of a cycle each joint trails the last, falloff as an amplitude multiplier per joint and phase), noise (joint/tip, axis, amplitude, seed and cycles; three seeded sines that loop seamlessly) or pulse (joint/tip, axis, amplitude, at and width in seconds). On a looping clip cycles is rounded to a whole number so the loop closes. Layers are evaluated inside the pose sampler, before retargeting and everything after it (joint limits, the ground solve, secondary motion), so playback, get_pose, measure_clip, bake_physics and every baked export see them without being asked. While any layer is solo only solo layers play in Rigsmith; an export ignores solo and goes by mute alone. Layers live in the project sidecar only (save_project) — a saved or exported glb carries the flattened channels and no layer data, and a library pack written with save_pack bakes a layered clip the same way. set_layer adds, replaces, removes or moves one layer in one undo step; apply_clip takes and get_clip reports a layers array, and an apply_clip that leaves layers out keeps the clip's existing stack (an empty array clears it). merge_layers bakes the unmuted stack into ordinary keys and clears it. Mirroring a clip does not mirror its layers.`,
	},
	{
		.name = "pins",
		.hook = "Holding joints in place while another is posed: set_pins, pose_joint, and what a pin does on a grounded clip.",
		.text = `A pin holds a joint where it stands while another joint is dragged: position (Pin position) keeps the joint at a point, rotation (Pin angle) keeps its orientation, a foot flat on the floor. It is the whole of how a figure sits, squats or reaches without its hands and feet sliding: pin both feet, pull the hips down, and the legs fold to keep them. set_pins pins by joint name, each captured from the pose showing — give clip and time to choose it — and clear drops them; get_pins reads the set and how well each held. pose_joint is the drag itself, made by a caller: move (a delta) or target (a point) drags the joint, turn {axis, angle} turns it, and it runs the same gesture the mouse does — one whole-body solve over every pin, the grab and the joint limits, with balance leaning the body over pinned feet — and keys the result like releasing the mouse with Auto-key on. Its answer has the joint's miss against the point asked for and every pin's residual, which is how far that pin ended from its point on the body as it is shown, so a pin that could not hold says so rather than reporting zero. A pin the gesture cannot reach (a limb too short, a joint limit, a foot that cannot stay flat at that depth) reports its miss and the body stops where the pins allow it; unpin one, or ask for less. A clip with a ground spec is shown with the floor solve applied, which lifts or lowers the whole figure so its feet touch the floor. So the contacts planted at that moment are held in place by the gesture as well, and a contact the gesture would push below the floor is held on it: pull a dog's pelvis down with both hind paws pinned and the front paws stay on the floor, the legs fold, and nothing lifts the pelvis back up. A pin on a foot's position and angle already holds the toe below it, which is not pinned a second time. Pins belong to the session — they are not saved with the project and go when a document loads. Posing over a clip is one undo step per keyed gesture.`,
	},
};

<*
 The tool table as an index: `[{name, listed}, …]`, or with each tool's
 description when the caller can afford one.

 Read off the `ToolDef` rather than from a list kept beside it, which is the
 whole point — the schema a tool validates against is the only description of it
 that cannot be wrong, and a hand-written index of a surface this wide is a
 promise to keep two things in step forever.

 `with_descriptions` is the difference between the two doors. A script's
 `crig.help()` carries them, because a script filters the index before anything
 reaches the reply and pays for only the rows it returns. The wire's index does
 not, because it goes straight into the model's context and twenty-seven
 descriptions are thirteen thousand characters — which is the cost this whole
 arrangement exists to avoid. Names are enough to choose from; `{"tool":name}`
 is how the choice is then read.
*>
fn void append_tool_index(DString* out, ToolTable* server, bool with_descriptions)
{
	out.append_char('[');
	for (usz i = 0; i < server.tools_len; i++)
	{
		ToolDef* tool = &server.tools[i];
		if (i > 0) out.append_char(',');
		out.append_string(`{"name":`);
		append_json_string(out, tool.name);
		out.appendf(`,"listed":%s`, tool.hidden ? "false" : "true");
		if (with_descriptions)
		{
			out.append_string(`,"description":`);
			append_json_string(out, tool.description);
		}
		out.append_char('}');
	}
	out.append_char(']');
}

<*
 One tool's registration: `{name, listed, description, schema}`.

 The same bytes on both doors — `get_api_docs` with a `tool` and a script's
 `crig.help(name)` — because it is one function and neither of them formats
 anything of its own.

 @return `false when no tool has that name, having written nothing.`
*>
fn bool append_tool_help(DString* out, ToolTable* server, String name)
{
	for (usz i = 0; i < server.tools_len; i++)
	{
		ToolDef* tool = &server.tools[i];
		if (tool.name != name) continue;

		out.append_string(`{"name":`);
		append_json_string(out, tool.name);
		out.appendf(`,"listed":%s,"description":`, tool.hidden ? "false" : "true");
		append_json_string(out, tool.description);
		// Verbatim: it is already JSON, and quoting it would hand back the
		// characters of the schema instead of the schema.
		out.append_string(`,"schema":`);
		out.append_string(tool.input_schema.len > 0 ? tool.input_schema : "{}");
		out.append_char('}');
		return true;
	}
	return false;
}

// The sentence a bad `topic` or `tool` gets: every name that would have worked.
// A refusal that lists the alternatives is one retry; a refusal that does not is
// a guess.
fn void append_topic_names(DString* detail) @local
{
	for (usz i = 0; i < DOC_TOPICS.len; i++)
	{
		if (i > 0) detail.append_string(i + 1 == DOC_TOPICS.len ? " and " : ", ");
		detail.append_string(DOC_TOPICS[i].name);
	}
}

<*
 get_api_docs.

 @param args : `{"topic": name | "all"} or {"tool": name}; omit both for the index.`
 @param detail : `Filled with what was asked for and what exists, when this faults.`
 @return? DOCS_BAD_ARGS : `No topic or tool of that name, or both were asked for at once.`
*>
fn String? api_docs(AppState* app, Object* args, DString* detail)
{
	String topic = "";
	String tool = "";
	if (args != null && args.is_keyable())
	{
		if (try asked = args.get_string("topic")) topic = asked.trim();
		if (try asked = args.get_string("tool")) tool = asked.trim();
	}

	if (topic.len > 0 && tool.len > 0)
	{
		detail.appendf(
			`get_api_docs takes "topic" or "tool", not both: a topic is a convention every tool follows and a tool is one tool's own arguments. Ask for %s, then for %s.`,
			topic, tool);
		return DOCS_BAD_ARGS~;
	}

	// Every path but a plain topic reads the registry, and that is not worth a
	// branch: the table is literals and one pointer, so building it costs a memcpy
	// of a few kilobytes of stack, and there is no second surface to keep in step
	// with the wire's.
	ToolTable server = new_tool_table(app);

	if (tool.len > 0)
	{
		DString out = dstring::new(mem);
		defer out.free();
		if (!append_tool_help(&out, &server, tool))
		{
			detail.appendf(
				`there is no tool called %s. get_api_docs with no arguments lists every one of them, listed or not.`,
				tool);
			return DOCS_BAD_ARGS~;
		}
		return out.copy_str(mem);
	}

	if (topic == "all") return api_docs_all(&server);
	if (topic.len == 0) return api_docs_index(&server);

	foreach (DocTopic entry : DOC_TOPICS)
	{
		if (entry.name != topic) continue;
		DString out = dstring::new(mem);
		defer out.free();
		out.appendf(`{"version":%d,"topic":`, API_DOCS_VERSION);
		append_json_string(&out, entry.name);
		out.append_string(`,"text":`);
		append_json_string(&out, entry.text);
		out.append_char('}');
		return out.copy_str(mem);
	}

	detail.appendf(`there is no topic called %s. The topics are `, topic);
	append_topic_names(detail);
	detail.append_string(`, or "all" for every one of them.`);
	return DOCS_BAD_ARGS~;
}

<*
 The index: what to ask for next, and nothing a caller has to read past.

 The hidden count is counted rather than written down, because a sentence saying
 twenty-one when the table says twenty-two is the kind of small lie that costs an
 agent a retry.
*>
fn String api_docs_index(ToolTable* server)
{
	DString out = dstring::new(mem);
	defer out.free();
	append_preamble(&out);

	usz hidden = 0;
	for (usz i = 0; i < server.tools_len; i++)
	{
		if (server.tools[i].hidden) hidden++;
	}

	DString reading = dstring::new(mem);
	defer reading.free();
	reading.append_string(`No arguments gives this index. {"topic":"ground"} returns one section in full, {"topic":"all"} returns every section — about twelve thousand characters — and {"tool":"apply_clip"} returns that tool's own description and JSON Schema off the registration itself, which is the same answer a script gets from crig.help(name).`);
	reading.appendf(
		` %d of the tools below are not in tools/list; they are registered and dispatched all the same, and a script reaches each one as crig.ops.<camelCase of its name>. See the scripting topic.`,
		hidden);
	out.append_string(`,"reading":`);
	append_json_string(&out, reading.str_view());

	out.append_string(`,"topics":[`);
	foreach (usz i, DocTopic entry : DOC_TOPICS)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"name":`);
		append_json_string(&out, entry.name);
		out.append_string(`,"hook":`);
		append_json_string(&out, entry.hook);
		out.append_char('}');
	}
	out.append_string(`],"tools":`);
	append_tool_index(&out, server, false);
	out.append_char('}');
	return out.copy_str(mem);
}

// Every section, keyed by name — the shape this document had before it was
// sectioned, less the tool summaries the registry now answers for.
fn String api_docs_all(ToolTable* server)
{
	DString out = dstring::new(mem);
	defer out.free();
	append_preamble(&out);
	foreach (DocTopic entry : DOC_TOPICS)
	{
		out.append_char(',');
		append_json_string(&out, entry.name);
		out.append_char(':');
		append_json_string(&out, entry.text);
	}
	out.append_string(`,"tools":`);
	append_tool_index(&out, server, false);
	out.append_char('}');
	return out.copy_str(mem);
}

// The version and the two conventions no section is without. Leaves the object
// open for whatever the caller asked for.
fn void append_preamble(DString* out) @local
{
	out.appendf(`{"version":%d,"space":`, API_DOCS_VERSION);
	append_json_string(out, DOCS_SPACE);
	out.append_string(`,"units":`);
	out.append_string(DOCS_UNITS);
}

fn String? tool_get_api_docs(Object* args, void* user_data, DString* detail) @private
{
	return api_docs((AppState*)user_data, args, detail);
}

// The resource takes no arguments, so it answers with the lot. A client fetches
// a resource because it asked for one, which is the opposite of the always-on
// cost the sectioning exists to cut.
<*
 The API document as three's `get_api_docs` section for Rigsmith.

 Kept as a function because `api_docs_all` builds it from the registrations and
 the `crig://api-docs` resource the tests serve wants the whole of it.
*>
fn String crig_api_docs(AppState* app)
{
	ToolTable server = new_tool_table(app);
	return api_docs_all(&server);
}

<*
 One string in, the docs it names out — the `crig.help(name)` renderer.

 The scripting side of `api_docs`, reading the module-global `tools` table rather
 than building one, because a script only reaches this after `install_crig_script`
 has filled it. The order is tool-first: `crig.help` is documented as "one tool's
 description and JSON Schema", so a name that is both — none are — reads as the
 tool. `""` is the index, `"all"` is every section, a topic name is that section,
 and anything else falls back to the index so a wrong guess still learns what it
 could have asked.

 @return `The docs as JSON, owned by the caller.`
*>
fn String crig_help_text(String name)
{
	if (name.len == 0) return api_docs_index(&tools);
	if (name == "all") return api_docs_all(&tools);

	DString out = dstring::new(mem);
	defer out.free();
	if (append_tool_help(&out, &tools, name)) return out.copy_str(mem);

	foreach (DocTopic entry : DOC_TOPICS)
	{
		if (entry.name != name) continue;
		out.clear();
		out.appendf(`{"version":%d,"topic":`, API_DOCS_VERSION);
		append_json_string(&out, entry.name);
		out.append_string(`,"text":`);
		append_json_string(&out, entry.text);
		out.append_char('}');
		return out.copy_str(mem);
	}

	return api_docs_index(&tools);
}
