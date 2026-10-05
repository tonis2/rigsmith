<*
 The 3D View header's Joints | Pose switch: what a drag on a joint changes.

 Joints moves the joint on the model, with the model at rest. Pose edits the
 animation chosen in the timeline, with that animation on show. Blender's Edit
 and Pose modes, as two words in the header rather than a key to remember — the
 answer to "once a clip is on, how do I move a joint again".

 Nothing is decided here: a click calls `enter_joint_stage`/`enter_pose_stage`,
 and the lit side is polled from `AppState.stage` each frame, since playing a
 clip moves the switch to Pose from places that do not know it exists.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const String STAGE_SWITCH_ID = "stage-switch";

String[2] stage_options = { "Joints", "Pose" };

// Slimmer than the panel segmented control, to sit inside the view's header.
const SegmentedStyle STAGE_SWITCH_STYLE = {
	.fill = BTN,
	.hover = BTN_HOVER,
	.selected = ACCENT,
	.border = PANEL_BORDER,
	.text = TEXT,
	.selected_text = DOT_OUTLINE,
	.border_radius = R8,
	.text_size = 12.0,
	.pad_x = 10.0,
	.height = 22.0,
};

// Between the switch and the tint buttons beside it.
const float STAGE_SWITCH_GAP = 10.0;

struct StageSwitch (Widget)
{
	int unused;
}

fn Element* StageSwitch.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	return @subtree(elem.ui)
	{
		@node((Segmented) { .options = stage_options[..], .selected = (sz)app.stage,
			.on_change = &stage_chosen, .style = STAGE_SWITCH_STYLE }).with_id(STAGE_SWITCH_ID);
	};
}

fn void StageSwitch.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (try Element* found = elem.find_id(STAGE_SWITCH_ID))
	{
		Segmented* strip = found.widget_as(Segmented);
		sz now = (sz)app.stage;
		if (!strip.tracking && strip.selected != now)
		{
			strip.selected = now;
			found.request_paint();
		}
	}
}

fn void stage_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	// A refused switch springs back on the next update, lit where it was; the
	// notice says why.
	if (index == 1)
	{
		(void)app.enter_pose_stage();
	}
	else
	{
		(void)app.enter_joint_stage();
	}
	app.refresh_ui();
}

// Which half of the switch the pointer is on.
fn String stage_tip(Element* holder, Vec2 pos)
{
	Element* strip = holder.children[0];
	if (pos.x - strip.absolute.x < strip.size.x * 0.5f)
	{
		return "Joints — a drag moves the joint on the model at rest";
	}
	return "Pose — a drag poses the joint; edits the animation chosen below";
}
