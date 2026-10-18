// Sharing a layer between animations from the layer strip: the row menu's Add
// to animations… (tick the clips to share the active layer with) and the + menu's
// Shared layer… (put a layer another clip shares onto this one). Either way the
// copies stay one layer: an edit of any is an edit of all, and each clip keeps its
// own weight, range and fit. The work is app/layer_edit.c3's.
module crig;

import cui;
import cui::widgets;
import std::math;

const String LAYER_SHARE_DIALOG_ID = "layer-share-dialog";
const String LAYER_SHARE_ADD_ID = "layer-share-add";
const String LAYER_SHARE_CANCEL_ID = "layer-share-cancel";
const String LAYER_SHARE_FIT_ID = "layer-share-fit";
const String LAYER_PICK_DIALOG_ID = "layer-pick-dialog";
const String LAYER_PICK_SELECT_ID = "layer-pick-select";
const String LAYER_PICK_FIT_ID = "layer-pick-fit";
const String LAYER_PICK_ADD_ID = "layer-pick-add";
const String ANIM_LAYER_SHARE_ID = "anim-layer-share";
const String ANIM_LAYER_UNLINK_ID = "anim-layer-unlink";
const String ANIM_LAYER_SHARED_ID = "anim-layer-shared";
const String ANIM_LAYER_FIT_ID = "anim-layer-fit";

String[3] layer_fit_options = { "Stretch to fit", "Keep seconds", "Repeat" };

// The rows the dialog lists, at most this many tall before it scrolls.
const usz LAYER_SHARE_ROWS_SHOWN = 8;
const float LAYER_SHARE_ROW_H = 26.0f;

fn AnimLayerFit layer_fit_of(usz index) => index == 1 ? KEEP : (index == 2 ? REPEAT : STRETCH);

// What a fit does, for the line under the chooser.
fn String layer_fit_note(AnimLayerFit fit)
{
	switch (fit)
	{
		case STRETCH: return "Spread over each animation's length: a cycle stays one cycle, faster or slower.";
		case KEEP: return "Its own seconds: a longer animation holds the last pose, a shorter one cuts it off.";
		case REPEAT: return "Its own seconds, over and over; it may end mid-cycle where the animation loops.";
	}
}

// ---------------------------------------------------------------------------
// Add to animations…

<*
 The row menu's Add to animations…: list every other animation of the character,
 ticked where it already shares the layer, and open the dialog.
*>
fn void anim_layer_menu_share(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, ANIM_LAYER_ROW_MENU_ID, false);
	if (!anim_can_rewrite(ui)) return;
	AnimLayer* layer = app.active_layer_ptr(app.editing);
	if (!layer) return;
	app.drop_layer_share_rows();
	usz bound = (usz)app.doc.animations.len();
	AnimRef[] targets = alloc::new_array(mem, AnimRef, (sz)bound);
	usz count;
	for (usz i = 0; i < bound; i++)
	{
		AnimRef ref = app.resolve_bound((sz)i);
		if (!ref.valid() || ref.same(app.editing) || !app.clip(ref)) continue;
		targets[count++] = ref;
	}
	app.layer_share_held = alloc::new_array(mem, bool, (sz)count);
	app.layer_share_labels = alloc::new_array(mem, String, (sz)count);
	app.layer_share_ids = alloc::new_array(mem, String, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		AnimTemplate* clip = app.clip(targets[i]);
		bool held = layer.link.len > 0 && clip.layer_linked(layer.link) >= 0;
		app.layer_share_held[i] = held;
		app.layer_share_labels[i] = held ? string::format(mem, "%s (shares it)", clip.name) : clip.name.copy(mem);
		app.layer_share_ids[i] = string::format(mem, "layer-share-row-%d", i);
	}
	app.layer_share_targets = targets[:count];
	app.layer_share_heading = string::format(mem, "Add layer \"%s\" to:", layer.name);
	app.layer_share_fit = layer.own_clock() ? (usz)layer.fit : 0;
	set_dialog_open(ui, LAYER_SHARE_DIALOG_ID, true);
}

fn Element* build_layer_share_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	usz count = app.layer_share_labels.len;
	float list_h = (float)math::min(math::max(count, (usz)1), LAYER_SHARE_ROWS_SHOWN) * LAYER_SHARE_ROW_H;
	return @subtree(ui)
	{
		@tree((Column) { .size = { 380, 0 }, .gap = ANIM_GAP })
		{
			@node((Label) { .text = app.layer_share_heading, .size = ANIM_TEXT_SIZE, .color = TEXT });
			if (count == 0)
			{
				@node((Label) { .text = "This character has no other animations.", .size = 12, .color = TEXT_DIM });
			}
			else
			{
				@tree((Scroll) { .size = { 0, list_h } })
				{
					@tree((Column) { .gap = 4 })
					{
						for (usz i = 0; i < count; i++)
						{
							@node((Checkbox) { .label = app.layer_share_labels[i], .checked = app.layer_share_held[i],
								.style = CHECKBOX_STYLE }).with_id(app.layer_share_ids[i]);
						}
					};
				};
			}
			@node((Label) { .text = "Timing in each animation", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((Segmented) { .options = layer_fit_options[..], .selected = (sz)app.layer_share_fit,
				.on_change = &layer_share_fit_chosen, .style = SEGMENTED_STYLE }).with_id(LAYER_SHARE_FIT_ID);
			@node((Label) { .text = layer_fit_note(layer_fit_of(app.layer_share_fit)), .size = 12, .color = TEXT_DIM });
			@node((Label) { .text = "The copies stay one layer: edit it in any animation and all of them follow.",
				.size = 12, .color = TEXT_DIM });
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button("Add", &layer_share_add)).with_id(LAYER_SHARE_ADD_ID);
				@node(panel_button("Cancel", &layer_share_closed)).with_id(LAYER_SHARE_CANCEL_ID);
			};
		};
	};
}

fn void layer_share_closed(Ui* ui) => set_dialog_open(ui, LAYER_SHARE_DIALOG_ID, false);

fn void layer_share_fit_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	app.layer_share_fit = index;
}

fn void layer_share_add(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	sz at = app.active_layer_of(app.editing);
	if (at < 0) { layer_share_closed(ui); return; }
	AnimRef[] picked = alloc::new_array(mem, AnimRef, (sz)app.layer_share_targets.len);
	defer if (picked.len > 0) alloc::free(mem, picked);
	usz count;
	foreach (usz i, target : app.layer_share_targets)
	{
		if (app.layer_share_held[i]) continue;
		Element*? box = ui.find_id(app.layer_share_ids[i]);
		if (try box) if (box.widget_as(Checkbox).checked) picked[count++] = target;
	}
	if (count == 0)
	{
		app.@notice("tick the animations to add the layer to");
		return;
	}
	String name = app.clip(app.editing).layers[(usz)at].name.tcopy();
	usz added = app.share_layer(app.editing, (usz)at, picked[:count], layer_fit_of(app.layer_share_fit));
	layer_share_closed(ui);
	if (added == 0)
	{
		app.@notice("the layer could not be added to those animations");
	}
	else
	{
		app.@notice("\"%s\" now plays in %d more animation%s — edit it in any of them and all follow · Ctrl+Z undoes",
			name, added, added == 1 ? "" : "s");
	}
	app.refresh_timeline_tracks(app.editing);
	refresh_animations_view(ui);
}

// ---------------------------------------------------------------------------
// Shared layer…

<*
 The + menu's Shared layer…: list the layers other animations share that this
 one does not have yet, and open the dialog.
*>
fn void anim_layer_add_shared(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, ANIM_LAYER_MENU_ID, false);
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	AnimPack* pack = app.authored();
	if (!clip || !pack) return;
	app.drop_layer_share_rows();
	StringList names;
	names.init(mem);
	defer names.free();
	StringList links;
	links.init(mem);
	defer links.free();
	foreach (&other : pack.clips) foreach (&layer : other.layers)
	{
		if (layer.link.len == 0 || clip.layer_linked(layer.link) >= 0) continue;
		bool seen = false;
		foreach (link : links.array_view()) if (link == layer.link) { seen = true; break; }
		if (seen) continue;
		links.push(layer.link);
		names.push(string::tformat("%s (from %s)", layer.name, other.name));
	}
	if (links.len() == 0)
	{
		app.@notice("no other animation shares a layer yet — right-click a layer and choose Add to animations…");
		return;
	}
	app.layer_pick_names = alloc::new_array(mem, String, (sz)names.len());
	app.layer_pick_links = alloc::new_array(mem, String, (sz)links.len());
	foreach (usz i, name : names.array_view()) app.layer_pick_names[i] = name.copy(mem);
	foreach (usz i, link : links.array_view()) app.layer_pick_links[i] = link.copy(mem);
	app.layer_pick_row = 0;
	app.layer_share_fit = 0;
	set_dialog_open(ui, LAYER_PICK_DIALOG_ID, true);
}

fn Element* build_layer_pick_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return @subtree(ui)
	{
		@tree((Column) { .size = { 380, 0 }, .gap = ANIM_GAP })
		{
			@node((Label) { .text = "The layer to put on this animation", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((Select) { .options = app.layer_pick_names, .selected = app.layer_pick_row, .width = 340,
				.style = VIEW_MENU_STYLE, .on_change = &layer_pick_chosen }).with_id(LAYER_PICK_SELECT_ID);
			@node((Label) { .text = "Timing", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((Segmented) { .options = layer_fit_options[..], .selected = (sz)app.layer_share_fit,
				.on_change = &layer_share_fit_chosen, .style = SEGMENTED_STYLE }).with_id(LAYER_PICK_FIT_ID);
			@node((Label) { .text = layer_fit_note(layer_fit_of(app.layer_share_fit)), .size = 12, .color = TEXT_DIM });
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button("Add", &layer_pick_add)).with_id(LAYER_PICK_ADD_ID);
				@node(panel_button("Cancel", &layer_pick_closed));
			};
		};
	};
}

fn void layer_pick_closed(Ui* ui) => set_dialog_open(ui, LAYER_PICK_DIALOG_ID, false);

fn void layer_pick_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	app.layer_pick_row = index;
}

fn void layer_pick_add(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	if (app.layer_pick_row >= app.layer_pick_links.len) { layer_pick_closed(ui); return; }
	String link = app.layer_pick_links[app.layer_pick_row].tcopy();
	layer_pick_closed(ui);
	if (app.add_shared_layer(app.editing, link, layer_fit_of(app.layer_share_fit)) < 0)
	{
		app.@notice("that layer could not be put on this animation");
		return;
	}
	app.@notice("the shared layer now plays here too — edit it in any animation and all follow · Ctrl+Z undoes");
	app.refresh_timeline_tracks(app.editing);
	refresh_animations_view(ui);
}

// ---------------------------------------------------------------------------
// The row menu's Unlink, and the form's fit

fn void anim_layer_menu_unlink(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, ANIM_LAYER_ROW_MENU_ID, false);
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) return;
	if (app.unlink_layer(app.editing, (usz)at))
	{
		app.@notice("this animation's copy is its own now; the others still share theirs · Ctrl+Z undoes");
	}
	app.refresh_timeline_tracks(app.editing);
	refresh_animations_view(ui);
}

fn void anim_layer_fit_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) { refresh_animations_view(ui); return; }
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	edited.fit = layer_fit_of(index);
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	app.refresh_timeline_tracks(app.editing);
	refresh_animations_view(ui);
}
