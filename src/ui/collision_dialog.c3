<*
 The self-collision check as the user sees it (C5): one control, a line for
 the two states worth a line, and the Advanced dialog behind them — all of
 it only while the system is switched on in Settings
 (`CrigConfig.self_collision`); off, none of this is built.

 *Prevent intersections* sits in the Animations pane beside Auto-key, since
 posing is where it acts. With it on and the mesh keeping up, that is all
 there is: a joint pushed into the body stops at it, and nothing says so —
 a stop the user made by pushing needs no caption. The status line appears
 only when the check is not simply on: intersections allowed, or live
 blocking reduced or paused for a mesh that cannot keep up, with how to
 retry. Everything else lives behind the clip menu's Collision…: the clearance, the
 bisection depth and time budget, the excluded pairs with a way to add and
 remove them, a switch to draw the last contact, and the diagnostics of
 the last check.

 The plan asked for the exceptional controls to be inspectable but out of the
 ordinary workflow, and for a mesh that cannot keep up to say so; the status
 line is where the latter is said.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const String ANIM_PREVENT_ID = "anim-prevent-intersections";
const String ANIM_COLLISION_STATUS_ID = "anim-collision-status";
const String COLLISION_DIALOG_ID = "collision-dialog";
const String COLLISION_CLEARANCE_ID = "collision-clearance";
const String COLLISION_STEPS_ID = "collision-steps";
const String COLLISION_BUDGET_ID = "collision-budget";
const String COLLISION_APPLY_ID = "collision-apply";
const String COLLISION_RESET_ID = "collision-reset";
const String COLLISION_EXCLUDE_ID = "collision-exclude-selected";
const String COLLISION_DONE_ID = "collision-done";
const String COLLISION_DIAGNOSTICS_ID = "collision-diagnostics";
const String COLLISION_SHOW_CONTACTS_ID = "collision-show-contacts";

fn void anim_prevent_toggled(Ui* ui, bool checked)
{
	AppState* app = ui.inherit(AppState)!!;
	app.set_prevent_intersections(checked);
	app.refresh_ui();
	refresh_animations_view(ui);
}

<*
 What the check has to say right now: one line when it is not simply on,
 and nothing — an empty string, no allocation — when it is. Owned by the
 caller when not empty.
*>
fn String collision_status_text(AppState* app)
{
	if (app.doc.allow_intersections)
	{
		return "Intersections allowed — joints may pass through the body.".copy(mem);
	}
	if (app.collision_mode == PAUSED)
	{
		float per_test = app.last_block.tests > 0 ? app.last_block.seconds / (float)app.last_block.tests : 0.0f;
		return string::format(mem, "Live blocking paused — %.0f ms per test on this mesh. Toggle Prevent intersections to retry.",
			per_test * 1000.0f);
	}
	if (app.collision_mode == REDUCED)
	{
		return string::format(mem, "Live blocking reduced — %.0f ms a move on this mesh. Toggle Prevent intersections to retry in full.",
			app.last_block.seconds * 1000.0f);
	}
	return "";
}

<*
 Whether the pane has a status line to build at all. The pane's snapshot
 carries the two facts this reads, so the line comes and goes with them.
*>
fn bool collision_status_shown(AppState* app) => app.config.self_collision
	&& (app.doc.allow_intersections || app.collision_mode != FULL);

<*
 The status line: a LiveLabel, so its text follows the check without
 rebuilding the pane. Full width, one row high.
*>
fn LiveLabel collision_status_line()
	=> { .text_of = &collision_status_line_text, .size = { 0, TREE_STYLE.row_height }, .text_size = 12, .color = TEXT_DIM };

fn String collision_status_line_text(Element* elem) @private => collision_status_text(elem.inherit(AppState)!!);

// ---------------------------------------------------------------------------
// The Advanced dialog

fn void collision_dialog_clicked(Ui* ui)
{
	anim_clip_menu_closed(ui);
	set_dialog_open(ui, COLLISION_DIALOG_ID, true);
}

fn void collision_dialog_closed(Ui* ui) => set_dialog_open(ui, COLLISION_DIALOG_ID, false);

// Rebuilt from scratch: the exclusion rows are part of the body, and a row
// removed has to leave the tree.
fn void collision_dialog_refresh(Ui* ui)
{
	set_dialog_open(ui, COLLISION_DIALOG_ID, false);
	set_dialog_open(ui, COLLISION_DIALOG_ID, true);
}

fn Element* build_collision_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { 390, 0 }, .gap = ANIM_GAP })
		{
			@tree((Row) { .gap = ANIM_GAP })
			{
				@tree((Column) { .gap = ANIM_GAP })
				{
					@node((Label) { .text = "Clearance (% of model)", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 120, .style = TEXT_FIELD_STYLE }).with_id(COLLISION_CLEARANCE_ID);
				};
				@tree((Column) { .gap = ANIM_GAP })
				{
					@node((Label) { .text = "Search steps", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 120, .style = TEXT_FIELD_STYLE }).with_id(COLLISION_STEPS_ID);
				};
				@tree((Column) { .gap = ANIM_GAP })
				{
					@node((Label) { .text = "Budget (ms)", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 120, .style = TEXT_FIELD_STYLE }).with_id(COLLISION_BUDGET_ID);
				};
			};
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button("Apply", &collision_apply_clicked)).with_id(COLLISION_APPLY_ID);
				@node(panel_button("Reset to defaults", &collision_reset_clicked)).with_id(COLLISION_RESET_ID);
			};
			@node((Label) { .text = "Search steps: how finely a blocked move is bisected. Over budget, the check is reduced or paused.",
				.size = 12, .color = TEXT_DIM });
			@node((Checkbox) { .label = "Draw the contact that stopped the last move", .checked = app.show_collision_contacts,
				.on_change = &collision_show_contacts_toggled, .style = CHECKBOX_STYLE }).with_id(COLLISION_SHOW_CONTACTS_ID);

			@node((Label) { .text = "Excluded pairs — never tested against each other", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			usz listed;
			foreach (entry : app.doc.collision_exclusions.array_view())
			{
				Dot* a = app.doc.find(entry.a);
				Dot* b = app.doc.find(entry.b);
				if (!a || !b) continue;
				listed++;
				@tree((Row) { .gap = ANIM_GAP, .cross_align = CENTER })
				{
					@node((OwnedLabel) { .text = string::format(mem, "%s — %s", dot_label(a), dot_label(b)),
						.size = ANIM_TEXT_SIZE, .color = TEXT });
					@node((CollisionExclusionRemove) { .a = entry.a, .b = entry.b });
				};
			}
			if (listed == 0)
			{
				@node((Label) { .text = "None. Regions that blend into each other and modelled contacts are already left alone.",
					.size = 12, .color = TEXT_DIM });
			}
			@node(panel_button("Exclude the two selected joints", &collision_exclude_selected)).with_id(COLLISION_EXCLUDE_ID);

			@node((Label) { .text = "Last check", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((OwnedLabel) { .text = collision_diagnostics_text(app), .size = 12, .color = TEXT_DIM })
				.with_id(COLLISION_DIAGNOSTICS_ID);
			@node((OwnedLabel) { .text = collision_pairs_text(app), .size = 12, .color = TEXT_DIM });
			@node(panel_button("Done", &collision_dialog_closed)).with_id(COLLISION_DONE_ID);
		};
	};
	Element* clearance = body.find_id(COLLISION_CLEARANCE_ID)!!;
	clearance.widget_as(TextField).set_text(clearance, string::tformat("%.4g", app.collision_clearance_fraction() * 100.0f));
	Element* steps = body.find_id(COLLISION_STEPS_ID)!!;
	steps.widget_as(TextField).set_text(steps, string::tformat("%d", app.collision_search_steps_setting()));
	Element* budget = body.find_id(COLLISION_BUDGET_ID)!!;
	budget.widget_as(TextField).set_text(budget, string::tformat("%.4g", app.collision_budget_seconds() * 1000.0f));
	return body;
}

<*
 A Label that owns its text — for the lines here that are formatted from the
 document when the dialog opens. A `Label` borrows, and a temporary would be
 released before the dialog painted; see `ExportSummary` for the same reason
 said at length.
*>
struct OwnedLabel (Widget)
{
	String text; // owned; freed at unmount
	float size;
	Color color;
}

fn Element* OwnedLabel.build(&self, Element* elem) @dynamic
{
	return @subtree(elem.ui)
	{
		@node((Label) { .text = self.text, .size = self.size, .color = self.color });
	};
}

fn void OwnedLabel.unmount(&self, Element* elem) @dynamic
{
	if (self.text.len > 0) alloc::free(mem, self.text.ptr);
	self.text = {};
}

// A dot's name, or what the rig calls an unnamed one. Temporary.
fn String dot_label(Dot* dot) @private => dot.name.len > 0 ? dot.name : string::tformat("bone_%d", dot.id);

// Owned by the caller.
fn String collision_diagnostics_text(AppState* app)
{
	if (!app.collision_policy.ready)
	{
		return "No body measured yet — the check starts with the first gesture.".copy(mem);
	}
	CollisionBlock block = app.last_block;
	if (!block.tested)
	{
		return string::format(mem, "Mode %s · %d modelled contacts · no gesture checked yet.",
			app.collision_mode.label(), app.collision_policy.rest_contacts.len);
	}
	return string::format(mem, "Mode %s · %d tests in %.1f ms · %s%s",
		app.collision_mode.label(), block.tests, block.seconds * 1000.0f,
		block.blocked ? "stopped at the mesh" : "clear",
		block.unreached ? string::tformat(", target %.3f short", block.residual) : "");
}

// Owned by the caller; empty before any check.
// The last narrow phase's pairs by reading. Neighboring and excluded regions
// are pruned in the broad phase before anything is counted, so the two
// readings appear here only for a triangle no joint weights.
fn String collision_pairs_text(AppState* app)
{
	CollisionPairCounts counts = app.last_block.counts;
	if (!app.last_block.tested) return "";
	return string::format(mem, "Pairs reaching the narrow phase: %d tested · %d shared topology · %d one patch · %d rest contacts",
		counts.candidates, counts.shared_topology, counts.shared_influence, counts.rest_contacts);
}

fn void collision_show_contacts_toggled(Ui* ui, bool checked)
{
	AppState* app = ui.inherit(AppState)!!;
	app.show_collision_contacts = checked;
	app.refresh_ui();
}

fn void collision_apply_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	float? percent = field_text(ui, COLLISION_CLEARANCE_ID).to_float();
	if (catch percent)
	{
		app.@notice("Enter the clearance as a percentage of the model's size, for example 0.5.");
		return;
	}
	if (!app.set_collision_clearance(percent / 100.0f))
	{
		app.@notice("The clearance must be above 0 and at most %.0f%% of the model.", MAX_COLLISION_CLEARANCE * 100.0f);
		return;
	}
	int? steps = field_text(ui, COLLISION_STEPS_ID).to_int();
	if (catch steps)
	{
		app.@notice("Enter the search steps as a whole number, 1 to %d.", MAX_COLLISION_SEARCH_STEPS);
		return;
	}
	if (!app.set_collision_search_steps(steps))
	{
		app.@notice("Search steps must be 1 to %d.", MAX_COLLISION_SEARCH_STEPS);
		return;
	}
	float? budget = field_text(ui, COLLISION_BUDGET_ID).to_float();
	if (catch budget)
	{
		app.@notice("Enter the budget in milliseconds, for example 40.");
		return;
	}
	if (!math::is_finite(budget) || budget <= 0.0f)
	{
		app.@notice("The budget must be above 0 ms.");
		return;
	}
	app.collision_budget = budget / 1000.0f;
	app.collision_mode = FULL;
	app.@notice("Collision: clearance %.2g%%, %d search steps, %.0f ms budget.",
		app.collision_clearance_fraction() * 100.0f, app.collision_search_steps_setting(), budget);
	collision_dialog_refresh(ui);
}

fn void collision_reset_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.doc.collision_clearance = 0.0f;
	app.collision_search_steps_override = 0;
	app.collision_budget = 0.0f;
	app.rebuild_collision_policy();
	collision_dialog_refresh(ui);
}

fn void collision_exclude_selected(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.selection_count() != 2)
	{
		app.@notice("Select exactly two joints to exclude — shift-click adds one to the selection.");
		return;
	}
	uint a = app.selected;
	uint b = app.also_selected[0];
	if (!app.set_collision_exclusion(a, b, true))
	{
		app.@notice("Those two are already excluded from each other.");
		return;
	}
	Dot* one = app.doc.find(a);
	Dot* other = app.doc.find(b);
	app.@notice("%s and %s are now never tested against each other. Ctrl+Z undoes.",
		one ? dot_label(one) : "?", other ? dot_label(other) : "?");
	collision_dialog_refresh(ui);
}

<*
 The Remove button on one excluded pair: a Button that knows which pair it
 is for, since a plain handler has no argument to carry it.
*>
struct CollisionExclusionRemove (Widget)
{
	uint a;
	uint b;
}

fn Element* CollisionExclusionRemove.build(&self, Element* elem) @dynamic
{
	return @subtree(elem.ui)
	{
		@node(panel_button("Remove", &collision_exclusion_remove_clicked));
	};
}

fn Vec2 CollisionExclusionRemove.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	Vec2 size = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return size;
}

fn void collision_exclusion_remove_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	// The pair is on the widget the button was built by, and the click fired
	// with the pointer over that button — `shells_row_under_pointer`'s walk.
	for (Element* at = ui.hovered; at != null; at = at.parent)
	{
		if (!at.is_widget(CollisionExclusionRemove)) continue;
		CollisionExclusionRemove* row = at.widget_as(CollisionExclusionRemove);
		if (app.set_collision_exclusion(row.a, row.b, false))
		{
			app.@notice("The pair is tested against each other again. Ctrl+Z undoes.");
		}
		break;
	}
	collision_dialog_refresh(ui);
}
