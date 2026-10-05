<*
 The Pose tab of the N-panel: what is done to the pose on show, as against what
 is done to the clip (the Animations dock) or to one joint (the Joint tab).

 Three Disclosure sections, built in `joint_panel.c3`:

 - **Pose** — Rest pose, Mirror pose, Copy / Paste / Paste mirrored. The same
   handlers the dock's key toolbar used to call (`animation_actions.c3`).
 - **Posing options** — Balance and the list of pinned joints (`locks.c3`),
   built here as `PosePinList`.
 - **Pose library** — `AnimPosesPanel` (`animation_poses.c3`), moved whole.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const String POSE_SECTION_ID = "pose-section";
const String POSE_OPTIONS_SECTION_ID = "pose-options-section";
const String POSE_LIBRARY_SECTION_ID = "pose-library-section";
const String POSE_PINS_ID = "pose-pins";
const String POSE_PIN_LIST_ID = "pose-pin-list";
const String POSE_PIN_CLEAR_ID = "pose-pin-clear";
const String POSE_PIN_NONE_ID = "pose-pin-none";
// Rows the pin list shows before it scrolls.
const float POSE_PIN_ROWS = 5;

// The pose library and its neighbours live in the N-panel's Pose tab, so a
// change to any of them rebuilds the dock (which shows the pending pose) and
// the panel.
fn void refresh_pose_views(Ui* ui)
{
	refresh_animations_view(ui);
	refresh_joint_panel(ui);
}

// A hash of the anchor list, so the tab notices a pin set or cleared anywhere —
// the padlocks, the viewport menu, MCP — without being told.
fn uint lock_list_hash(AppState* app)
{
	uint hash = 2166136261u;
	foreach (lock : app.position_locks)
	{
		hash = (hash ^ lock.dot_id) * 16777619u;
		hash = (hash ^ (lock.position ? 1u : 0u) ^ (lock.rotation ? 2u : 0u)) * 16777619u;
	}
	return hash;
}

fn void pose_pin_chosen(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	if (row >= app.position_locks.len) return;
	app.select(app.position_locks[row].dot_id);
	app.refresh_ui();
	refresh_joint_panel(ui);
}

fn void pose_pins_clear_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	usz held = app.position_locks.len;
	if (AnimTemplate* clip = app.clip_pins_drive() ? app.clip(app.editing) : null) held = math::max(held, (usz)clip.pins.len);
	app.clear_editor_pins();
	app.@notice(held == 0 ? "nothing is pinned" : "all pins cleared");
	app.refresh_ui();
	refresh_joint_panel(ui);
}

<*
 The pinned joints, one row each, with what is held (position, angle or both),
 and a Clear all. Clicking a row selects that joint.
*>
struct PosePinList (Widget)
{
	TreeRow[] rows;
}

fn void PosePinList.release(&self)
{
	foreach (row : self.rows)
	{
		row.label.free(mem);
	}
	if (self.rows.len > 0) alloc::free(mem, self.rows);
	self.rows = {};
}

fn void PosePinList.unmount(&self, Element* elem) @dynamic => self.release();

fn Element* PosePinList.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	PositionLock[] locks = app.position_locks;
	usz selected = ~(usz)0;
	if (locks.len > 0)
	{
		self.rows = alloc::new_array(mem, TreeRow, locks.len);
		foreach (usz i, lock : locks)
		{
			Dot* dot = app.doc.find(lock.dot_id);
			String name = dot && dot.name.len > 0 ? dot.name : "Unnamed joint";
			self.rows[i] = {
				.label = name.copy(mem),
				.trailing = lock.position && lock.rotation ? "position + angle"
					: (lock.position ? "position" : "angle"),
			};
			if (lock.dot_id == app.selected) selected = i;
		}
	}
	return @subtree(elem.ui)
	{
		@tree((Column) { .gap = 4 })
		{
			if (locks.len == 0)
			{
				@node((Label) { .text = "No joints pinned. Pin one with the padlocks on the Joint tab.",
					.size = 12.0f, .color = TEXT_DIM }).with_id(POSE_PIN_NONE_ID);
			}
			else
			{
				@tree((Scroll) { .size = { 0, math::min((float)locks.len, POSE_PIN_ROWS) * TREE_STYLE.row_height } })
				{
					@node((Tree) { .rows = self.rows, .selected = selected, .on_select = &pose_pin_chosen,
						.style = TREE_STYLE }).with_id(POSE_PIN_LIST_ID);
				};
				@node(panel_button("Clear all", &pose_pins_clear_clicked)).with_id(POSE_PIN_CLEAR_ID);
			}
		};
	};
}

fn Vec2 PosePinList.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}
