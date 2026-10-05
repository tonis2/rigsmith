// Contact lanes on the sheet: when a foot (or a hand) is planted, drawn as bars
// under the Poses lane. Drag an end or the bar, drag on an empty lane to add,
// right-click for Delete. Each edit is one undo step; see app/contacts.c3.
module crig;
import cui;
import cui::widgets;
import std::math;

const String ANIM_ADD_CONTACT_ID = "anim-add-contact";
const String ANIM_CONTACT_MENU_ID = "anim-contact-menu";
const String ANIM_CONTACT_DELETE_ID = "anim-contact-delete";
const String ANIM_CONTACT_ADD_HERE_ID = "anim-contact-add-here";
const String ANIM_CONTACT_REMOVE_LANE_ID = "anim-contact-remove-lane";

fn void anim_contact_landed(Ui* ui, bool ok) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (ok) app.show_edited();
	refresh_animations_view(ui);
}

fn void anim_add_contact_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui) || !app.clip(app.editing)) return;
	anim_contact_landed(ui, app.add_contact_for_selected(app.editing));
}

<*
 A bar was dragged: its window moves or one of its ends does, by `delta`
 seconds. A one-shot clip's window stops at the clip's ends.
*>
fn void anim_contact_bar_edited(Ui* ui, TimelineBar bar, TimelineGrip grip, float delta)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (bar.pin)
	{
		anim_pin_bar_edited(app, clip, bar, grip, delta);
		return;
	}
	if (!clip || clip.duration <= 0.0f || bar.window >= clip.ground.feet.len) return;
	AnimFoot foot = clip.ground.feet[bar.window];
	float d = delta / clip.duration;
	float down = foot.down;
	float span = foot.span();
	switch (grip)
	{
		case MOVE: down += d;
		case FROM:
			down += d;
			span -= d;
		case TO: span += d;
	}
	if (!clip.loop)
	{
		if (grip == MOVE) down = math::clamp(down, 0.0f, 1.0f - span);
		if (down < 0.0f)
		{
			span += down;
			down = 0.0f;
		}
		span = math::min(span, 1.0f - down);
	}
	anim_contact_landed(ui, app.set_contact_window(app.editing, bar.window, down, span));
}

<*
 A pin lane's bar dragged: its ends (or the whole bar, on a move) shifted by
 `delta` seconds and kept inside the clip, landed as one undo step.
*>
fn void anim_pin_bar_edited(AppState* app, AnimTemplate* clip, TimelineBar bar, TimelineGrip grip, float delta)
{
	if (!clip || clip.duration <= 0.0f || bar.window >= clip.pins.len) return;
	AnimPin pin = clip.pins[bar.window];
	float from = pin.from;
	float to = pin.to;
	switch (grip)
	{
		case MOVE:
			delta = math::clamp(delta, -from, clip.duration - to);
			from += delta;
			to += delta;
		case FROM: from = math::clamp(from + delta, 0.0f, to);
		case TO: to = math::clamp(to + delta, from, clip.duration);
	}
	String joint = pin.joint.tcopy();
	RigView? opened = app.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);
	foreach (usz j, name : app.names_for(&view, app.editing))
	{
		if (name != joint || j >= view.dot_ids.len) continue;
		(void)app.set_clip_pin_window(view.dot_ids[j], from, to, -1.0f);
		break;
	}
	app.refresh_ui();
}

fn void anim_contact_bar_added(Ui* ui, TimelineLane lane, float from, float to)
{
	AppState* app = ui.inherit(AppState)!!;
	if (lane.pin) return;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip || clip.duration <= 0.0f || lane.joint.len == 0) return;
	String joint = lane.joint.tcopy();
	anim_contact_landed(ui, app.add_contact_window(app.editing, joint, from / clip.duration, (to - from) / clip.duration));
}

fn void open_anim_contact_menu(Ui* ui, Vec2 at) @private
{
	Element* elem = ui.find_id(ANIM_CONTACT_MENU_ID)!!;
	Dialog* menu = elem.widget_as(Dialog);
	menu.at = at;
	menu.placed = true;
	menu.set_open(elem, true);
}

fn void anim_contact_bar_context(Ui* ui, TimelineBar bar, Vec2 pixel)
{
	AppState* app = ui.inherit(AppState)!!;
	if (bar.pin) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip || bar.window >= clip.ground.feet.len) return;
	app.anim_contact_window = (sz)bar.window;
	app.anim_contact_foot = contact_first_of(clip.ground, clip.ground.feet[bar.window].joint);
	open_anim_contact_menu(ui, pixel);
}

fn void anim_contact_lane_context(Ui* ui, TimelineLane lane, float at, Vec2 pixel)
{
	AppState* app = ui.inherit(AppState)!!;
	if (lane.pin) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) return;
	usz foot = contact_first_of(clip.ground, lane.joint);
	if (foot >= clip.ground.feet.len) return;
	app.anim_contact_window = -1;
	app.anim_contact_foot = foot;
	app.anim_contact_time = at;
	open_anim_contact_menu(ui, pixel);
}

// The joint the open menu is about, or "" (temporary).
fn String anim_contact_menu_joint(AppState* app) @private
{
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip || app.anim_contact_foot >= clip.ground.feet.len) return "";
	return clip.ground.feet[app.anim_contact_foot].joint.tcopy();
}

fn void anim_contact_delete(Ui* ui)
{
	set_dialog_open(ui, ANIM_CONTACT_MENU_ID, false);
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui) || app.anim_contact_window < 0) return;
	anim_contact_landed(ui, app.delete_contact_window(app.editing, (usz)app.anim_contact_window));
}

fn void anim_contact_add_here(Ui* ui)
{
	set_dialog_open(ui, ANIM_CONTACT_MENU_ID, false);
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	String joint = anim_contact_menu_joint(app);
	if (!clip || clip.duration <= 0.0f || joint.len == 0) return;
	float down = app.anim_contact_time / clip.duration;
	float span = CONTACT_NEW_SPAN;
	if (!clip.loop) span = math::min(span, 1.0f - down);
	foreach (foot : clip.ground.feet)
	{
		if (foot.joint != joint) continue;
		float ahead = clip.loop ? phase_wrapped(foot.down - down) : foot.down - down;
		if (ahead > 0.0f) span = math::min(span, ahead);
	}
	anim_contact_landed(ui, app.add_contact_window(app.editing, joint, down, span));
}

fn void anim_contact_remove_lane(Ui* ui)
{
	set_dialog_open(ui, ANIM_CONTACT_MENU_ID, false);
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	String joint = anim_contact_menu_joint(app);
	if (joint.len == 0) return;
	anim_contact_landed(ui, app.remove_contact_lane(app.editing, joint));
}

fn Element* build_anim_contact_menu(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	String remove = "Remove this contact lane";
	float width = widgets::PANEL_MIN_W;
	foreach (label : (String[]) { "Delete contact", "Add contact here", remove })
	{
		width = math::max(width, widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x);
	}
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			if (app.anim_contact_window >= 0)
			{
				@node((PopupMenuItem) { .item = { .label = "Delete contact", .on_select = &anim_contact_delete },
					.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_CONTACT_DELETE_ID);
			}
			else
			{
				@node((PopupMenuItem) { .item = { .label = "Add contact here", .on_select = &anim_contact_add_here },
					.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_CONTACT_ADD_HERE_ID);
			}
			@node((PopupMenuItem) { .item = { .label = remove, .on_select = &anim_contact_remove_lane },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_CONTACT_REMOVE_LANE_ID);
		};
	};
}
