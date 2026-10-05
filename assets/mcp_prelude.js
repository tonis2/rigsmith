// ============================================================================
// The `crig` object a run_script body is written against.
//
// This file is evaluated into three's JavaScript runtime at boot by
// `src/mcp/script.c3`, on top of two native doors it binds onto the global:
//
//   __crig_call(name, argsJson) -> resultJson   every tool in the server
//   __crig_help(name)           -> jsonText      the conventions and tool reference
//
// It is JavaScript rather than C3 on purpose: the shape of an API is the part
// that gets changed most and understood least, and putting it here means a text
// edit rather than a rebuild.
//
// crig's tools are also reachable directly over MCP, by name — which is how
// get_scene and the rest answer a client that is not scripting. What this file
// adds is the convenience of driving them from a script, and reaching three's
// own scene API in the same one.
//
// crig.data — the document as live objects with writable dot properties — is not
// here: it needed a property model over the document that went when crig stopped
// being its own program, and the reads it replaced are crig.ops.getSkeleton and
// crig.ops.getScene.
//
// One rule worth knowing before the first script: each ops call is its own undo
// entry, exactly as if it had arrived over the wire on its own, so a script that
// writes many is not yet one Ctrl+Z.
//
// **Write modern JavaScript here.** quickjs-ng takes everything through ES2023 and
// several things past it — classes with private fields, spread, `?.`, `??`, `??=`,
// `Object.groupBy`, optional catch binding. Three exceptions, all about how this
// file is evaluated rather than about the engine: no `import`/`export` and no
// top-level `await`, because it is a classic script and not a module, which is why
// the surface is hung off `globalThis` below; and no `await` anywhere, because
// nothing drains the promise job queue.
// ============================================================================

((global) => {
    "use strict";

    // Extended rather than replaced, so a future door that also wants `crig` finds
    // whatever is already there.
    global.crig ??= {};
    const crig = global.crig;

    // Objects in, objects out. Every tool answers JSON, so the parse is the normal
    // path — but a tool that ever answers a bare sentence delivers the sentence
    // rather than a parse error about it. A refused call throws an Error carrying
    // the tool's own refusal, so try/catch reads exactly what the wire would say.
    const call = (name, args = {}) => {
        const reply = __crig_call(name, JSON.stringify(args));
        if (typeof reply !== "string" || reply.length === 0) return null;
        try {
            return JSON.parse(reply);
        } catch {
            return reply;
        }
    };

    const isSpec = (value) =>
        value !== null && typeof value === "object" && !Array.isArray(value);

    // A wrapper whose first argument may be either the one field it usually is or
    // the whole argument object. `getPose("walk")`, `getPose("walk", {t: 0.5})` and
    // `getPose({clip: "walk", t: 0.5})` are the same call: the short form is what a
    // caller writes nine times out of ten, and the long one is how everything else
    // in the schema is still reachable without a second function per tool.
    const one = (tool, key) => (value, extra) => call(tool, {
        ...(isSpec(value) ? value : value == null ? {} : { [key]: value }),
        ...(isSpec(extra) ? extra : {}),
    });

    // A wrapper over a tool whose arguments have no single obvious field —
    // apply_clip and its kind, where the spec *is* the argument.
    const spec = (tool) => (args) => call(tool, args);

    crig.ops = {
        // Reading.
        getScene: spec("get_scene"),
        getSkeleton: spec("get_skeleton"),
        getPose: one("get_pose", "clip"),
        getClip: one("get_clip", "clip"),
        measureClip: one("measure_clip", "clip"),
        getWeights: one("get_weights", "dot"),
        getShells: one("get_shells", "limit"),
        // crig's own docs: getCrigDocs("ground") for one section, ("all") for every
        // one, () for the index. A tool's own arguments are crig.help(name), which
        // is the same renderer and one word shorter.
        getCrigDocs: one("get_crig_docs", "topic"),

        // The rig.
        applyPlan: one("apply_plan", "plan"),
        buildBody: spec("build_body"),

        // A list is the ordinary argument and {ops: [...]} is the wire's shape, so
        // both work: editRig([{op: "move", ...}]) and editRig({ops: [...]}).
        editRig: (ops) => call("edit_rig", Array.isArray(ops) ? { ops } : ops),

        // Clips.
        applyClip: spec("apply_clip"),
        deleteClip: one("delete_clip", "clip"),
        savePack: one("save_pack", "name"),
        saveProject: spec("save_project"),

        // Placing hands and feet by point: solveTargets answers with a keyframe,
        // applyClip bakes it. See the targets doc topic.
        solveTargets: spec("solve_targets"),

        // Baking stance feet still so a clip stops skating. See the ground topic.
        plantFeet: one("plant_feet", "clip"),

        // Offsetting a few joints of a clip over a range, the rest untouched. See
        // the editing topic.
        patchClip: spec("patch_clip"),

        // A whole locomotion cycle from foot paths. See the gaits topic.
        authorGait: spec("author_gait"),

        // A clip's layer stack: setLayer({clip, op, layer}) edits one layer,
        // mergeLayers("walk") bakes the stack into the base. See the layers topic.
        setLayer: spec("set_layer"),
        mergeLayers: one("merge_layers", "clip"),

        // Pins and posing: getPins() reads the set, setPins({pins: [{joint}]}) or
        // setPins({clear: true}) changes it, poseJoint({joint, move: [x,y,z]}) is the
        // viewport drag and keys it. See the pins doc topic.
        getPins: spec("get_pins"),
        setPins: (pins) => call("set_pins", Array.isArray(pins) ? { pins } : pins),
        poseJoint: spec("pose_joint"),

        // Taking a clip off the character, or out of the loaded model for good.
        unbindClip: one("unbind_clip", "clip"),
        deleteModelClip: one("delete_model_clip", "clip"),

        // Physics.
        setSecondaryMotion: spec("set_secondary_motion"),
        bakePhysics: spec("bake_physics"),

        // Weights.
        paintWeights: spec("paint_weights"),
        pinWeights: spec("pin_weights"),

        // mode is what this is always called with, and the dot only matters to
        // falloff: showWeights("falloff", "hip"), showWeights("off").
        showWeights: (mode, dot) => call("show_weights", {
            ...(isSpec(mode) ? mode : { mode }),
            ...(typeof dot === "string" ? { dot } : {}),
        }),

        // The player and the camera.
        play: one("play", "clip"),
        stop: spec("stop"),
        setCamera: one("set_camera", "view"),

        // A contact sheet, in the reply rather than to the script, which gets the
        // receipt — a script has no use for base64. For the window as it stands,
        // three's own three.screenshot(path) is the door.
        render: spec("render"),

        // These step the same history the viewport and the wire step — a script's
        // own ops each recorded an entry, so an undo here takes back the last of
        // them. Present so a name that reads as an action is one.
        undo: spec("undo"),
        redo: spec("redo"),
    };

    // The conventions and the tool reference. `crig.help()` is the index — every
    // tool, whether or not a client was told about it — `crig.help("apply_clip")`
    // is one tool's description and its JSON Schema off the registration itself,
    // and `crig.help("ground")` is a conventions section.
    //
    // Only what a script returns or logs reaches the reply, so filtering the index
    // down to the one line that answers the question costs nothing:
    //
    //   crig.help().tools.filter(t => t.name.includes("weight")).map(t => t.name)
    //   crig.help("apply_clip").schema
    crig.help = (name) => JSON.parse(__crig_help(String(name ?? "")));

    // The raw door, for a tool this file has no wrapper for — a new one, or one
    // whose short form does not reach the argument being set. Same objects in and
    // out as every wrapper above.
    crig.call = call;
})(globalThis);
