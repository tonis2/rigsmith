// Check: what is wrong with the edited clip, as flags on the sheet's ruler and
// a short list in a small dialog, with the one-click fix (Close loop). Plant feet
// lives in the Clip tools menu beside it.
module crig;
import cui;
import cui::widgets;
import std::math;

const String ANIM_CHECK_ID = "anim-check";
const String ANIM_CHECK_LIST_ID = "anim-check-list";
const String ANIM_PLANT_FEET_ID = "anim-plant-feet";
const String ANIM_CHECK_CLOSE_LOOP_ID = "anim-check-close-loop";
const String ANIM_CHECK_HIDE_ID = "anim-check-hide";
const String ANIM_CHECK_DIALOG_ID = "anim-check-dialog";
// Rows the list shows before it scrolls.
const float ANIM_CHECK_ROWS = 4;

fn void anim_check_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.clip(app.editing))
	{
		app.@notice("pick an animation to check first");
		return;
	}
	usz found = app.check_clip(app.editing);
	app.@notice("%s", found == 0 ? "Check found nothing wrong with this animation."
		: "Check marked the problems on the timeline; click one to go there.");
	set_dialog_open(ui, ANIM_CHECK_DIALOG_ID, true);
	refresh_anim_check(ui);
}

// The sheet's flags and the results dialog both follow the last Check.
fn void refresh_anim_check(Ui* ui)
{
	refresh_animations_view(ui);
	if (try Element* dialog = ui.find_id(ANIM_CHECK_DIALOG_ID)) dialog.request_build();
}

fn void anim_check_hide(Ui* ui)
{
	ui.inherit(AppState)!!.anim_check.free();
	set_dialog_open(ui, ANIM_CHECK_DIALOG_ID, false);
	refresh_animations_view(ui);
}

// The results, floating over the dock rather than pushing the sheet down. Not
// modal: the flags on the ruler stay clickable while it is up.
fn Element* build_anim_check_body(Ui* ui)
{
	return @subtree(ui)
	{
		@tree((Column) { .size = { 420, 0 }, .gap = ANIM_GAP })
		{
			@node((AnimCheckPanel) { });
		};
	};
}

// A flag on the ruler or a row of the list: go to where the issue is.
fn void anim_check_go(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	if (index >= app.anim_check.issues.len) return;
	CheckIssue issue = app.anim_check.issues[index];
	anim_seek(ui, issue.time);
	app.@notice("%s at %.2f s", issue.label, issue.time);
}

fn void anim_plant_feet_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	if (!app.clip(app.editing)) return;
	PlantOutcome outcome;
	defer outcome.free();
	if (!app.plant_feet(app.editing, &outcome))
	{
		refresh_anim_check(ui);
		return;
	}
	app.show_edited();
	app.check_clip(app.editing);
	app.@notice("Planted the feet · sliding %.1f%% → %.1f%% of the height · Ctrl+Z undoes it",
		outcome.before.foot_slide * 100, outcome.after.foot_slide * 100);
	refresh_anim_check(ui);
}

fn void anim_check_close_loop(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	anim_close_loop_clicked(ui);
	if (app.anim_check.ran) app.check_clip(app.editing);
	refresh_anim_check(ui);
}

<*
 The result of the last Check, in its dialog: a line saying how it went, the
 fix, and a row per issue that jumps the playhead to it.
*>
struct AnimCheckPanel (Widget)
{
	TreeRow[] rows;
}

fn void AnimCheckPanel.release(&self)
{
	foreach (row : self.rows)
	{
		row.label.free(mem);
		row.trailing.free(mem);
	}
	if (self.rows.len > 0) alloc::free(mem, self.rows);
	self.rows = {};
}

fn void AnimCheckPanel.unmount(&self, Element* elem) @dynamic => self.release();

fn Element* AnimCheckPanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	CheckIssue[] issues = app.anim_check.issues;
	if (issues.len > 0)
	{
		self.rows = alloc::new_array(mem, TreeRow, issues.len);
		foreach (usz i, issue : issues)
		{
			self.rows[i] = { .label = issue.label.copy(mem), .trailing = issue.trailing.copy(mem) };
		}
	}
	AnimTemplate* clip = app.clip(app.editing);
	bool current = app.check_current(app.editing);
	String said = string::format(mem, "%s%s", issues.len == 0 ? "Check: nothing wrong found"
		: issues.len == 1 ? "Check: 1 problem" : string::tformat("Check: %d problems", issues.len),
		current ? "" : " · the animation changed since");
	return @subtree(elem.ui)
	{
		@tree((Column) { .gap = 4 })
		{
			@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
			{
				@node((OwnedLabel) { .text = said, .size = ANIM_TEXT_SIZE, .color = issues.len > 0 ? ACCENT : TEXT_DIM });
				if (clip && clip.loop)
				{
					@node(panel_button("Close loop", &anim_check_close_loop)).with_id(ANIM_CHECK_CLOSE_LOOP_ID);
				}
				if (!current) @node(panel_button("Check again", &anim_check_clicked)).with_id("anim-check-again");
				@node(panel_button("Hide", &anim_check_hide)).with_id(ANIM_CHECK_HIDE_ID);
			};
			if (self.rows.len > 0)
			{
				@tree((Scroll) { .size = { 0, math::min((float)self.rows.len, ANIM_CHECK_ROWS) * TREE_STYLE.row_height } })
				{
					@node((Tree) { .rows = self.rows, .selected = ~(usz)0, .on_select = &anim_check_go,
						.style = TREE_STYLE }).with_id(ANIM_CHECK_LIST_ID);
				};
			}
		};
	};
}

fn Vec2 AnimCheckPanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}
