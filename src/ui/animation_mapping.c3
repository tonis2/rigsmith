// Joint mapping: match the joints of a library clip that did not find a joint on
// this character, one dropdown each.
module crig;
import cui;
import cui::widgets;
import std::math;

const String ANIM_MAPPING_DIALOG_ID = "anim-mapping-dialog";
const String ANIM_FIX_MAPPING_ID = "anim-fix-mapping";
const String ANIM_FIX_MAPPING_INLINE_ID = "anim-fix-mapping-inline";
const String ANIM_MAPPING_APPLY_ID = "anim-mapping-apply";
const String ANIM_MAPPING_RESET_ID = "anim-mapping-reset";
const String ANIM_MAPPING_ALL_ID = "anim-mapping-all";
const float ANIM_MAPPING_W = 420;
const float ANIM_MAPPING_LIST_H = 300;

<*
 One row's dropdown of this character's joints, tagged with its row so Apply can
 read what every row says.
*>
struct AnimMappingPick (Widget)
{
	usz row;
}

fn Element* AnimMappingPick.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	MappingDraft* draft = &app.mapping_draft;
	usz chosen = self.row < draft.rows.len ? draft.rows[self.row].chosen : 0;
	return @subtree(elem.ui)
	{
		@node((Select) { .options = draft.options, .selected = chosen, .width = 200,
			.style = VIEW_MENU_STYLE, .searchable = draft.options.len > ANIM_CHOOSER_SEARCH_MIN });
	};
}

fn Vec2 AnimMappingPick.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}

fn void anim_fix_mapping_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	anim_clip_menu_closed(ui);
	if (!anim_can_rewrite(ui)) return;
	if (!app.clip_mappable(app.editing))
	{
		app.@notice("Only an animation from the library needs its joints matched; this one uses the character's own.");
		return;
	}
	bool all = app.unmatched_joints(app.editing) == 0;
	if (!app.open_mapping_draft(app.editing, all))
	{
		app.@notice("could not read the animation's joints");
		return;
	}
	set_dialog_open(ui, ANIM_MAPPING_DIALOG_ID, true);
}

fn void anim_mapping_closed(Ui* ui)
{
	set_dialog_open(ui, ANIM_MAPPING_DIALOG_ID, false);
	ui.inherit(AppState)!!.mapping_draft.free();
}

fn void anim_mapping_all_toggled(Ui* ui, bool checked)
{
	AppState* app = ui.inherit(AppState)!!;
	// The body is built on open, so reopening shows the new rows. Closing drops
	// the draft, so it is filled again in between.
	set_dialog_open(ui, ANIM_MAPPING_DIALOG_ID, false);
	if (!app.open_mapping_draft(app.editing, checked)) return;
	set_dialog_open(ui, ANIM_MAPPING_DIALOG_ID, true);
}

// What each dropdown says now, in row order; in tmem.
fn usz[] anim_mapping_choices(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	usz[] chosen = mem::temp_array(usz, app.mapping_draft.rows.len);
	foreach (usz i, row : app.mapping_draft.rows) chosen[i] = row.chosen;
	ui.@each(AnimMappingPick; pick)
	{
		usz row = pick.widget_as(AnimMappingPick).row;
		if (row < chosen.len && pick.children.len() > 0) chosen[row] = pick.children[0].widget_as(Select).selected;
	};
	return chosen;
}

fn void anim_mapping_apply(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	bool changed = app.apply_mapping_draft(anim_mapping_choices(ui));
	anim_mapping_closed(ui);
	if (!changed)
	{
		app.@notice("The joint matches are unchanged.");
		return;
	}
	app.@notice("Joint matches saved for this library file · Ctrl+Z undoes them");
	app.refresh_bound_rows();
	app.show_edited();
	refresh_animations_view(ui);
}

fn void anim_mapping_reset(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	String file = app.mapping_draft.file.tcopy();
	anim_mapping_closed(ui);
	if (!app.map_pack_joints(file, {}, reset: true))
	{
		app.@notice("This library file already uses the automatic matches.");
		return;
	}
	app.@notice("Back to the automatic joint matches · Ctrl+Z undoes it");
	app.refresh_bound_rows();
	app.show_edited();
	refresh_animations_view(ui);
}

fn Element* build_anim_mapping_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	MappingDraft* draft = &app.mapping_draft;
	AnimTemplate* clip = app.clip(app.editing);
	float list_h = math::min((float)draft.rows.len * 32.0f, ANIM_MAPPING_LIST_H);
	return @subtree(ui)
	{
		@tree((Column) { .size = { ANIM_MAPPING_W, 0 }, .gap = ANIM_GAP })
		{
			@node((OwnedLabel) { .text = string::format(mem, "Pick the joint of this character that plays each joint of %s.",
				clip ? clip.name : "the animation"), .size = ANIM_TEXT_SIZE, .color = TEXT });
			@node((Label) { .text = "(none) leaves that joint still. Saved for every animation from the same file.",
				.size = 12, .color = TEXT_DIM });
			@node((Checkbox) { .label = "Show matched joints too", .checked = draft.all,
				.on_change = &anim_mapping_all_toggled, .style = CHECKBOX_STYLE }).with_id(ANIM_MAPPING_ALL_ID);
			if (draft.rows.len == 0)
			{
				@node((Label) { .text = "Every joint this animation moves has a match.",
					.size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			}
			else
			{
				@tree((Scroll) { .size = { 0, list_h } })
				{
					@tree((Column) { .gap = 4 })
					{
						foreach (usz i, row : draft.rows)
						{
							@tree((Row) { .gap = ANIM_GAP, .cross_align = CENTER })
							{
								@tree((Column) { .size = { 180, 0 } })
								{
									@node((Label) { .text = row.source, .size = ANIM_TEXT_SIZE,
										.color = row.current == 0 ? ACCENT : TEXT });
								};
								@node((AnimMappingPick) { .row = i });
							};
						}
					};
				};
			}
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button("Apply", &anim_mapping_apply)).with_id(ANIM_MAPPING_APPLY_ID);
				@node(panel_button("Reset to automatic", &anim_mapping_reset)).with_id(ANIM_MAPPING_RESET_ID);
				@node(panel_button("Cancel", &anim_mapping_closed)).with_id("anim-mapping-cancel");
			};
		};
	};
}
