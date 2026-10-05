<*
 The layer strip: a clip's stack of layers, above the timeline.

 One row per layer, top of the stack first as in an image editor, and a Base row
 under them for the clip's own keys. A row carries an eye (mute), a solo switch,
 a kind icon, the name and what the layer is (kind, mode, weight). Clicking a row
 makes it the **active layer**: the timeline below shows and edits that layer's
 keys, and Key pose / Auto-key store a delta into it (app/layer_edit.c3).

 The Layers column's header holds + (a menu of the kinds) and Merge down (bake the
 whole stack into the base); right-click a row for Delete, Move up / down and
 Mask from selection / Clear mask. For the active layer a form follows, in three
 folding sections: Blend (name, mode, weight, range, fades), Motion (for a wave,
 noise or pulse: its joint, tip, axis and the numbers that shape it) and Mask.

 Every change is one edit of the clip through `land_clip`, so one undo step; the
 form's sliders land once, when the pointer is let go. Weight, mute and solo
 reach live playback at once, since a landed clip restarts the watched player.
*>
module crig;

import cui;
import cui::widgets;
import std::math;
import std::math::vector;

const String ANIM_LAYERS_ID = "anim-layers";
const String ANIM_LAYER_TREE_ID = "anim-layer-tree";
const String ANIM_LAYER_ADD_ID = "anim-layer-add";
const String ANIM_LAYER_MENU_ID = "anim-layer-menu";
const String ANIM_LAYER_ROW_MENU_ID = "anim-layer-row-menu";
const String ANIM_LAYERS_EMPTY_ID = "anim-layers-empty";
const String ANIM_LAYER_BLEND_ID = "anim-layer-blend";
const String ANIM_LAYER_MOTION_ID = "anim-layer-motion";
const String ANIM_LAYER_MASK_SECTION_ID = "anim-layer-mask-section";
const String ANIM_LAYER_KEYED_ID = "anim-layer-keyed";
const String ANIM_LAYER_OVERRIDE_ID = "anim-layer-override";
const String ANIM_LAYER_WAVE_ID = "anim-layer-wave";
const String ANIM_LAYER_NOISE_ID = "anim-layer-noise";
const String ANIM_LAYER_PULSE_ID = "anim-layer-pulse";
const String ANIM_LAYER_DELETE_ID = "anim-layer-delete";
const String ANIM_LAYER_UP_ID = "anim-layer-up";
const String ANIM_LAYER_DOWN_ID = "anim-layer-down";
const String ANIM_LAYER_MERGE_ID = "anim-layer-merge";
const String ANIM_LAYER_MASK_ID = "anim-layer-mask";
const String ANIM_LAYER_MASK_CLEAR_ID = "anim-layer-mask-clear";
const String ANIM_LAYER_NAME_ID = "anim-layer-name";
const String ANIM_LAYER_WEIGHT_ID = "anim-layer-weight";
const String ANIM_LAYER_MODE_ID = "anim-layer-mode";
const String ANIM_LAYER_JOINT_ID = "anim-layer-joint";
const String ANIM_LAYER_TIP_ID = "anim-layer-tip";
const String ANIM_LAYER_AXIS_ID = "anim-layer-axis";
const String ANIM_LAYER_SEED_ID = "anim-layer-seed";
const String ANIM_LAYER_AMPLITUDE_ID = "anim-layer-amplitude";
const String ANIM_LAYER_CYCLES_ID = "anim-layer-cycles";
const String ANIM_LAYER_LAG_ID = "anim-layer-lag";
const String ANIM_LAYER_FALLOFF_ID = "anim-layer-falloff";
const String ANIM_LAYER_PHASE_ID = "anim-layer-phase";
const String ANIM_LAYER_AT_ID = "anim-layer-at";
const String ANIM_LAYER_WIDTH_ID = "anim-layer-width";
const String ANIM_LAYER_START_ID = "anim-layer-start";
const String ANIM_LAYER_END_ID = "anim-layer-end";
const String ANIM_LAYER_FADE_IN_ID = "anim-layer-fade-in";
const String ANIM_LAYER_FADE_OUT_ID = "anim-layer-fade-out";

const ushort LAYER_ICON_KEYED = 21;
const ushort LAYER_ICON_WAVE = 22;
const ushort LAYER_ICON_NOISE = 23;
const ushort LAYER_ICON_PULSE = 24;
const ushort LAYER_ICON_BASE = 25;
const ushort LAYER_ICON_SOLO = 26;

// Most rows the list shows before it scrolls.
const usz LAYER_ROWS_SHOWN = 6;

String[2] layer_mode_options = { "Additive", "Override" };
String[3] layer_axis_options = { "X", "Y", "Z" };

// Which number a slider of the form edits.
enum LayerParam
{
	WEIGHT,
	AMPLITUDE,
	CYCLES,
	LAG,
	FALLOFF,
	PHASE,
	AT,
	WIDTH,
	START,
	END,
	FADE_IN,
	FADE_OUT,
}

fn String AnimLayerKind.label(self)
{
	switch (self)
	{
		case KEYED: return "Keyed";
		case WAVE: return "Wave";
		case NOISE: return "Noise";
		case PULSE: return "Pulse";
	}
}

fn ushort AnimLayerKind.icon(self)
{
	switch (self)
	{
		case KEYED: return LAYER_ICON_KEYED;
		case WAVE: return LAYER_ICON_WAVE;
		case NOISE: return LAYER_ICON_NOISE;
		case PULSE: return LAYER_ICON_PULSE;
	}
}

<*
 Draws the strip's icons with the painter's shapes, and hands the outliner's eye
 on to the outliner's painter.
*>
fn void paint_layer_icon(Painter* painter, Vec2 at, float size, ushort icon, bool dim)
{
	float r = size * 0.5f;
	Color ink = TEXT_DIM;
	switch (icon)
	{
		case LAYER_ICON_KEYED:
			// A key diamond.
			painter.line({ at.x - r * 0.7f, at.y }, { at.x, at.y - r * 0.7f }, 1.6f, ink);
			painter.line({ at.x, at.y - r * 0.7f }, { at.x + r * 0.7f, at.y }, 1.6f, ink);
			painter.line({ at.x + r * 0.7f, at.y }, { at.x, at.y + r * 0.7f }, 1.6f, ink);
			painter.line({ at.x, at.y + r * 0.7f }, { at.x - r * 0.7f, at.y }, 1.6f, ink);
		case LAYER_ICON_WAVE:
			Vec2 last = { at.x - r, at.y };
			for (int i = 1; i <= 8; i++)
			{
				float u = (float)i / 8.0f;
				Vec2 next = { at.x - r + 2.0f * r * u, at.y - r * 0.6f * math::sin(u * 2.0f * (float)math::PI) };
				painter.line(last, next, 1.6f, ink);
				last = next;
			}
		case LAYER_ICON_NOISE:
			float[7] ups = { 0.1f, -0.5f, 0.4f, -0.2f, 0.6f, -0.4f, 0.0f };
			Vec2 last = { at.x - r, at.y + r * ups[0] };
			for (usz i = 1; i < 7; i++)
			{
				Vec2 next = { at.x - r + 2.0f * r * (float)i / 6.0f, at.y + r * ups[i] };
				painter.line(last, next, 1.6f, ink);
				last = next;
			}
		case LAYER_ICON_PULSE:
			Vec2 last = { at.x - r, at.y + r * 0.5f };
			for (int i = 1; i <= 8; i++)
			{
				float u = (float)i / 8.0f * 2.0f - 1.0f;
				Vec2 next = { at.x + r * u, at.y + r * 0.5f - r * 1.1f * math::exp(-u * u * 6.0f) };
				painter.line(last, next, 1.6f, ink);
				last = next;
			}
		case LAYER_ICON_BASE:
			painter.rect({ at.x - r * 0.7f, at.y - r * 0.5f }, { r * 1.4f, r },
				{ .border_color = ink, .border_width = 1.5f, .border_radius = { 2, 2, 2, 2 } });
		case LAYER_ICON_SOLO:
			// A ring that fills when the layer is the only one heard.
			Color lit = dim ? (Color){ 0.40, 0.42, 0.50, 1.0 } : ACCENT;
			painter.circle(at, r * 0.75f, { .border_color = lit, .border_width = 1.5f });
			if (!dim) painter.circle(at, r * 0.4f, { .color = lit });
		default:
			paint_outliner_icon(painter, at, size, icon, dim);
	}
}

// The text a row ends with: what the layer is and how much of it is heard.
fn String layer_row_note(AnimLayer* layer)
{
	String mode = layer.mode == OVERRIDE ? "override" : "additive";
	return string::format(mem, "%s · %s · %d%%", layer.kind.label(), mode, (int)(layer.weight * 100.0f + 0.5f));
}

struct AnimLayerStrip (Widget)
{
	TreeRow[] rows;
	// The rig's joints as the joint and tip choosers list them; owned.
	String[] joints;
	String[] tips;
	String mask_text;
}

fn void AnimLayerStrip.release(&self)
{
	foreach (row : self.rows)
	{
		if (row.label.len > 0) alloc::free(mem, row.label.ptr);
		if (row.trailing.len > 0) alloc::free(mem, row.trailing.ptr);
	}
	if (self.rows.len > 0) alloc::free(mem, self.rows);
	foreach (name : self.joints) if (name.len > 0) alloc::free(mem, name.ptr);
	if (self.joints.len > 0) alloc::free(mem, self.joints);
	// The tips are the joints behind a "(chain)" entry: only that one is ours.
	if (self.tips.len > 0)
	{
		if (self.tips[0].len > 0) alloc::free(mem, self.tips[0].ptr);
		alloc::free(mem, self.tips);
	}
	if (self.mask_text.len > 0) alloc::free(mem, self.mask_text.ptr);
	self.rows = {};
	self.joints = {};
	self.tips = {};
	self.mask_text = "";
}

fn void AnimLayerStrip.unmount(&self, Element* elem) @dynamic => self.release();

fn Vec2 AnimLayerStrip.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	Vec2 inner = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ constraints.max.x, inner.y });
}

fn Slider layer_slider(String label, float value, float min, float max, float step, uint decimals,
	OnSlide on_commit, String suffix = "")
{
	return {
		.label = label,
		.suffix = suffix,
		.value = value,
		.min = min,
		.max = max,
		.step = step,
		.decimals = decimals,
		.on_commit = on_commit,
		.style = PHYSICS_SLIDER_STYLE,
		// Fills the column: the Layers column is a slice of the dock, not a fixed 250.
		.size = { 0, 0 },
	};
}

fn Element* AnimLayerStrip.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip)
	{
		// Nothing to layer: say so instead of drawing an empty column.
		return @subtree(elem.ui)
		{
			@tree((Column) { .gap = ANIM_GAP })
			{
				@node((Label) { .text = "Layers", .size = 15, .color = TEXT });
				@node((Label) { .text = "Pick an animation to add layers", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM })
					.with_id(ANIM_LAYERS_EMPTY_ID);
			};
		};
	}

	usz count = clip.layers.len;
	sz active = app.active_layer_of(app.editing);
	AnimLayer* layer = active >= 0 ? &clip.layers[(usz)active] : null;

	// The rows, top of the stack first, the base last.
	self.rows = alloc::new_array(mem, TreeRow, (sz)(count + 1));
	foreach (usz r, &row : self.rows)
	{
		if (r == count)
		{
			*row = {
				.label = "Base".copy(mem),
				.trailing = string::format(mem, "%d keys", clip.keyframes.len),
				.icon = LAYER_ICON_BASE,
			};
			continue;
		}
		AnimLayer* each = &clip.layers[count - 1 - r];
		*row = {
			.label = (each.name.len > 0 ? each.name : "Layer").copy(mem),
			.trailing = layer_row_note(each),
			.icon = each.kind.icon(),
		};
		row.toggles[0] = { .icon = OUTLINER_ICON_EYE, .on = !each.mute, .shown = true };
		row.toggles[1] = { .icon = LAYER_ICON_SOLO, .on = each.solo, .shown = true };
	}
	usz selected = active >= 0 ? count - 1 - (usz)active : count;

	// The joints a generator can start and end on.
	StringList names;
	names.init(mem);
	defer names.free();
	RigView? opened = app.open_rig(mem);
	if (try RigView view = opened)
	{
		defer view.free(mem);
		foreach (name : view.names) if (name.len > 0) names.push(name);
		self.joints = alloc::new_array(mem, String, (sz)names.len());
		foreach (usz i, name : names.array_view()) self.joints[i] = name.copy(mem);
	}
	usz joint_row = 0;
	usz tip_row = 0;
	if (layer && layer.procedural())
	{
		self.tips = alloc::new_array(mem, String, (sz)(self.joints.len + 1));
		self.tips[0] = "(follow the chain)".copy(mem);
		foreach (usz i, name : self.joints)
		{
			// Borrowed from `joints`, which outlives them both.
			self.tips[i + 1] = name;
			if (name == layer.joint) joint_row = i;
			if (layer.tip.len > 0 && name == layer.tip) tip_row = i + 1;
		}
	}
	// `release` frees tips[0] only; the rest are `joints`'.
	if (layer)
	{
		self.mask_text = layer.mask.len == 0 ? "Mask: the whole body".copy(mem)
			: string::format(mem, "Mask: %d joint%s (and everything below)", layer.mask.len, layer.mask.len == 1 ? "" : "s");
	}

	float list_h = (float)math::min(count + 1, LAYER_ROWS_SHOWN) * OUTLINER_STYLE.row_height;
	float duration = clip.duration;

	Element* body = @subtree(elem.ui)
	{
		@tree((Column) { .gap = ANIM_GAP })
		{
			// The header: the column's name, the new-layer menu, and the bake.
			@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = ANIM_GAP, .cross_align = CENTER })
			{
				@node((Label) { .text = "Layers", .size = 15, .color = TEXT });
				@tree(widgets::tip("Add layer — keyed, override, wave, noise or pulse"))
				{
					@node(panel_button("+ ▾", &anim_layer_add_clicked)).with_id(ANIM_LAYER_ADD_ID);
				};
				if (count > 0)
				{
					@node(panel_button("Merge down", &anim_layer_merge_clicked)).with_id(ANIM_LAYER_MERGE_ID);
				}
			};
			// The stack, top first, the base last. Right-click a layer for what can be
			// done to it.
			@tree((Scroll) { .size = { 0, list_h } })
			{
				@node((Tree) {
					.rows = self.rows,
					.selected = selected,
					.on_select = &anim_layer_row_chosen,
					.on_context = &anim_layer_row_context,
					.on_row_toggle = &anim_layer_row_toggled,
					.paint_icon = &paint_layer_icon,
					.style = OUTLINER_STYLE,
				}).with_id(ANIM_LAYER_TREE_ID);
			};
			if (layer)
			{
				// What the active layer blends with: its name, mode, weight, range, fades.
				Element* blend = @tree((Disclosure) {
					.label = "Blend", .expanded = !app.layer_blend_collapsed,
					.style = JOINT_SECTION_STYLE, .on_change = &layer_blend_section_changed })
				{
					@tree((Column) { .gap = ANIM_GAP })
					{
						@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = ANIM_GAP, .cross_align = CENTER })
						{
							@node((Label) { .text = "Name", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
							@node((TextField) { .width = 130, .style = TEXT_FIELD_STYLE, .placeholder = "layer name",
								.on_submit = &anim_layer_named }).with_id(ANIM_LAYER_NAME_ID);
						};
						@node((Segmented) { .options = layer_mode_options[..], .selected = layer.mode == OVERRIDE ? 1 : 0,
							.on_change = &anim_layer_mode_chosen, .style = SEGMENTED_STYLE }).with_id(ANIM_LAYER_MODE_ID);
						@node(layer_slider("Weight", layer.weight, 0.0f, 1.0f, 0.01f, 2, &anim_layer_weight_committed)).with_id(ANIM_LAYER_WEIGHT_ID);
						@node(layer_slider("Start", layer.start, 0.0f, duration, 0.05f, 2,
							&anim_layer_start_committed, " s")).with_id(ANIM_LAYER_START_ID);
						@node(layer_slider("End", layer.end, 0.0f, duration, 0.05f, 2,
							&anim_layer_end_committed, " s")).with_id(ANIM_LAYER_END_ID);
						@node(layer_slider("Fade in", layer.fade_in, 0.0f, duration, 0.05f, 2,
							&anim_layer_fade_in_committed, " s")).with_id(ANIM_LAYER_FADE_IN_ID);
						@node(layer_slider("Fade out", layer.fade_out, 0.0f, duration, 0.05f, 2,
							&anim_layer_fade_out_committed, " s")).with_id(ANIM_LAYER_FADE_OUT_ID);
					};
				};
				blend.with_id(ANIM_LAYER_BLEND_ID);

				if (layer.procedural())
				{
					// The generator: where it acts and the numbers that shape it.
					Element* motion = @tree((Disclosure) {
						.label = "Motion", .expanded = !app.layer_motion_collapsed,
						.style = JOINT_SECTION_STYLE, .on_change = &layer_motion_section_changed })
					{
						@tree((Column) { .gap = ANIM_GAP })
						{
							@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = ANIM_GAP, .cross_align = CENTER })
							{
								@node((Label) { .text = "Joint", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
								@node((Select) { .options = self.joints, .selected = joint_row, .width = 140,
									.style = VIEW_MENU_STYLE, .searchable = self.joints.len > ANIM_CHOOSER_SEARCH_MIN,
									.on_change = &anim_layer_joint_chosen }).with_id(ANIM_LAYER_JOINT_ID);
								if (layer.kind == WAVE)
								{
									@node((Label) { .text = "Tip", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
									@node((Select) { .options = self.tips, .selected = tip_row, .width = 150,
										.style = VIEW_MENU_STYLE, .searchable = self.tips.len > ANIM_CHOOSER_SEARCH_MIN,
										.on_change = &anim_layer_tip_chosen }).with_id(ANIM_LAYER_TIP_ID);
								}
								@node((Label) { .text = "Axis", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
								@node((Segmented) { .options = layer_axis_options[..], .selected = layer_axis_row(layer.axis),
									.on_change = &anim_layer_axis_chosen, .style = SEGMENTED_STYLE }).with_id(ANIM_LAYER_AXIS_ID);
								if (layer.kind == NOISE)
								{
									@node((Label) { .text = "Seed", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
									@node((TextField) { .width = 72, .style = TEXT_FIELD_STYLE, .placeholder = "0",
										.on_submit = &anim_layer_seed_submitted }).with_id(ANIM_LAYER_SEED_ID);
								}
							};
							@node(layer_slider("Amplitude", layer.amplitude * 180.0f / (float)math::PI, -180.0f, 180.0f, 1.0f, 0,
								&anim_layer_amplitude_committed, "°")).with_id(ANIM_LAYER_AMPLITUDE_ID);
							if (layer.kind != PULSE)
							{
								@node(layer_slider("Cycles", layer.cycles, 0.0f, 16.0f, 0.5f, 1,
									&anim_layer_cycles_committed)).with_id(ANIM_LAYER_CYCLES_ID);
							}
							if (layer.kind == WAVE)
							{
								@node(layer_slider("Lag", layer.lag, 0.0f, 1.0f, 0.01f, 2,
									&anim_layer_lag_committed)).with_id(ANIM_LAYER_LAG_ID);
								@node(layer_slider("Falloff", layer.falloff, 0.2f, 2.0f, 0.05f, 2,
									&anim_layer_falloff_committed)).with_id(ANIM_LAYER_FALLOFF_ID);
								@node(layer_slider("Phase", layer.phase, 0.0f, 1.0f, 0.01f, 2,
									&anim_layer_phase_committed)).with_id(ANIM_LAYER_PHASE_ID);
							}
							if (layer.kind == PULSE)
							{
								@node(layer_slider("At", layer.at, 0.0f, duration, 0.01f, 2,
									&anim_layer_at_committed, " s")).with_id(ANIM_LAYER_AT_ID);
								@node(layer_slider("Width", layer.width, 0.01f, 2.0f, 0.01f, 2,
									&anim_layer_width_committed, " s")).with_id(ANIM_LAYER_WIDTH_ID);
							}
						};
					};
					motion.with_id(ANIM_LAYER_MOTION_ID);
				}

				// Which joints the layer touches. Set from the row's right-click menu.
				Element* mask = @tree((Disclosure) {
					.label = "Mask", .expanded = !app.layer_mask_collapsed,
					.style = JOINT_SECTION_STYLE, .on_change = &layer_mask_section_changed })
				{
					@tree((Column) { .gap = ANIM_GAP })
					{
						@node((Label) { .text = self.mask_text, .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
						@node((Label) { .text = "Right-click the layer to set the mask from the selected joints, or clear it.",
							.size = 12, .color = TEXT_DIM });
					};
				};
				mask.with_id(ANIM_LAYER_MASK_SECTION_ID);
			}
		};
	};
	if (layer)
	{
		if (try Element* field = body.find_id(ANIM_LAYER_NAME_ID)) field.widget_as(TextField).set_text(field, layer.name);
		if (layer.kind == NOISE)
		{
			if (try Element* field = body.find_id(ANIM_LAYER_SEED_ID))
			{
				field.widget_as(TextField).set_text(field, string::tformat("%d", layer.seed));
			}
		}
	}
	return body;
}

// The axis a Y-up generator turns about, as the segment to light: -1 for one
// that is not along X, Y or Z (set through the tool, say).
fn sz layer_axis_row(Vec3 axis)
{
	if (axis.length_sq() < 1.0e-12f) return -1;
	Vec3 unit = axis.normalize();
	if (math::abs(unit.x) > 0.999f) return 0;
	if (math::abs(unit.y) > 0.999f) return 1;
	if (math::abs(unit.z) > 0.999f) return 2;
	return -1;
}

// ---------------------------------------------------------------------------
// The menu

fn Element* build_anim_layer_menu(Ui* ui)
{
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	String[5] labels = { "Keyed (additive)", "Keyed (override)", "Wave", "Noise", "Pulse" };
	float width = widgets::PANEL_MIN_W;
	foreach (label : labels)
	{
		width = math::max(width, widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x);
	}
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			@node((PopupMenuItem) { .item = { .label = labels[0], .on_select = &anim_layer_add_keyed },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_KEYED_ID);
			@node((PopupMenuItem) { .item = { .label = labels[1], .on_select = &anim_layer_add_override },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_OVERRIDE_ID);
			@node((PopupMenuItem) { .item = { .label = labels[2], .on_select = &anim_layer_add_wave },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_WAVE_ID);
			@node((PopupMenuItem) { .item = { .label = labels[3], .on_select = &anim_layer_add_noise },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_NOISE_ID);
			@node((PopupMenuItem) { .item = { .label = labels[4], .on_select = &anim_layer_add_pulse },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_PULSE_ID);
		};
	};
}

// The row menu: what is done to the layer under the pointer. A right-press makes
// the row the active layer first, so every item acts on the row that opened it.
fn void anim_layer_row_context(Ui* ui, usz row, Vec2 at)
{
	AppState* app = ui.inherit(AppState)!!;
	anim_layer_row_chosen(ui, row);
	// The Base row has no verbs: it is the clip's own keys.
	if (layer_of_row(app, row) < 0) return;
	Element*? elem = ui.find_id(ANIM_LAYER_ROW_MENU_ID);
	if (catch elem) return;
	Dialog* menu = elem.widget_as(Dialog);
	menu.at = at;
	menu.placed = true;
	menu.set_open(elem, true);
}

fn void anim_layer_row_menu_closed(Ui* ui) @private => set_dialog_open(ui, ANIM_LAYER_ROW_MENU_ID, false);

fn void anim_layer_menu_up(Ui* ui)
{
	anim_layer_row_menu_closed(ui);
	anim_layer_up_clicked(ui);
}

fn void anim_layer_menu_down(Ui* ui)
{
	anim_layer_row_menu_closed(ui);
	anim_layer_down_clicked(ui);
}

fn void anim_layer_menu_mask(Ui* ui)
{
	anim_layer_row_menu_closed(ui);
	anim_layer_mask_clicked(ui);
}

fn void anim_layer_menu_mask_clear(Ui* ui)
{
	anim_layer_row_menu_closed(ui);
	anim_layer_mask_clear_clicked(ui);
}

fn void anim_layer_menu_delete(Ui* ui)
{
	anim_layer_row_menu_closed(ui);
	anim_layer_delete_clicked(ui);
}

fn Element* build_anim_layer_row_menu(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	sz at = app.active_layer_of(app.editing);
	AnimLayer* layer = clip && at >= 0 ? &clip.layers[(usz)at] : null;
	bool none = layer == null;
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	float width = widgets::PANEL_MIN_W;
	foreach (label : (String[]) { "Move up", "Move down", "Mask from selection", "Clear mask", "Delete layer" })
	{
		width = math::max(width, widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x);
	}
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			@node((PopupMenuItem) { .item = { .label = "Move up", .on_select = &anim_layer_menu_up,
				.disabled = none || (usz)at + 1 >= clip.layers.len }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_UP_ID);
			@node((PopupMenuItem) { .item = { .label = "Move down", .on_select = &anim_layer_menu_down,
				.disabled = none || at == 0 }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_DOWN_ID);
			@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
			@node((PopupMenuItem) { .item = { .label = "Mask from selection", .on_select = &anim_layer_menu_mask,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_MASK_ID);
			@node((PopupMenuItem) { .item = { .label = "Clear mask", .on_select = &anim_layer_menu_mask_clear,
				.disabled = none || layer.mask.len == 0 }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_MASK_CLEAR_ID);
			@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
			@node((PopupMenuItem) { .item = { .label = "Delete layer", .on_select = &anim_layer_menu_delete,
				.disabled = none }, .style = DANGER_MENU_STYLE, .width = width }).with_id(ANIM_LAYER_DELETE_ID);
		};
	};
}

// The form's folding sections, remembered across runs.
fn void layer_blend_section_changed(Ui* ui, bool expanded) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.layer_blend_collapsed = !expanded;
	app.remember_ui();
}

fn void layer_motion_section_changed(Ui* ui, bool expanded)
{
	AppState* app = ui.inherit(AppState)!!;
	app.layer_motion_collapsed = !expanded;
	app.remember_ui();
}

fn void layer_mask_section_changed(Ui* ui, bool expanded) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.layer_mask_collapsed = !expanded;
	app.remember_ui();
}

fn void anim_layer_add_clicked(Ui* ui)
{
	if (!anim_can_rewrite(ui)) return;
	Element*? elem = ui.find_id(ANIM_LAYER_MENU_ID);
	if (catch elem) return;
	Dialog* menu = elem.widget_as(Dialog);
	menu.at = ui.input.mouse;
	menu.placed = true;
	menu.set_open(elem, true);
}

fn void anim_layer_add(Ui* ui, AnimLayerKind kind, AnimLayerMode mode) @private
{
	set_dialog_open(ui, ANIM_LAYER_MENU_ID, false);
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	if (app.add_clip_layer(app.editing, kind, mode) < 0)
	{
		app.@notice("this clip has no keys to lay a layer over");
		return;
	}
	app.refresh_timeline_tracks(app.editing);
	refresh_animations_view(ui);
}

fn void anim_layer_add_keyed(Ui* ui) => anim_layer_add(ui, KEYED, ADDITIVE);
fn void anim_layer_add_override(Ui* ui) => anim_layer_add(ui, KEYED, OVERRIDE);
fn void anim_layer_add_wave(Ui* ui) => anim_layer_add(ui, WAVE, ADDITIVE);
fn void anim_layer_add_noise(Ui* ui) => anim_layer_add(ui, NOISE, ADDITIVE);
fn void anim_layer_add_pulse(Ui* ui) => anim_layer_add(ui, PULSE, ADDITIVE);

// ---------------------------------------------------------------------------
// Rows

// A row of the list to the index of its layer in the stack, -1 for the base.
fn sz layer_of_row(AppState* app, usz row) @private
{
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip || row >= clip.layers.len) return -1;
	return (sz)(clip.layers.len - 1 - row);
}

fn void anim_layer_row_chosen(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	app.set_active_layer(app.editing, layer_of_row(app, row));
	app.refresh_timeline_tracks(app.editing);
	refresh_animations_view(ui);
}

fn void anim_layer_row_toggled(Ui* ui, usz row, usz column)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = layer_of_row(app, row);
	if (at < 0 || !anim_can_rewrite(ui)) return;
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	if (column == 0) { edited.mute = !edited.mute; }
	else { edited.solo = !edited.solo; }
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

// ---------------------------------------------------------------------------
// The verbs

fn void anim_layer_delete_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) return;
	if (app.remove_clip_layer(app.editing, (usz)at)) app.@notice("layer deleted — Undo brings it back");
	app.refresh_timeline_tracks(app.editing);
	refresh_animations_view(ui);
}

fn void anim_layer_move(Ui* ui, bool up) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) return;
	(void)app.move_clip_layer(app.editing, (usz)at, up);
	refresh_animations_view(ui);
}

fn void anim_layer_up_clicked(Ui* ui) => anim_layer_move(ui, true);
fn void anim_layer_down_clicked(Ui* ui) => anim_layer_move(ui, false);

fn void anim_layer_merge_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	usz merged = clip ? clip.layers.len : 0;
	if (app.merge_clip_layers(app.editing))
	{
		app.@notice("merged %d layer%s into the base keys — Undo restores the stack", merged, merged == 1 ? "" : "s");
	}
	app.show_edited();
	refresh_animations_view(ui);
}

fn void anim_layer_mask_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) return;
	String[] picked = app.selected_joint_names(mem);
	defer
	{
		foreach (name : picked) name.free(mem);
		if (picked.len > 0) alloc::free(mem, picked);
	}
	if (picked.len == 0)
	{
		app.@notice("select joints in the viewport first — the layer will touch only those and what hangs below them");
		return;
	}
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	foreach (entry : edited.mask) if (entry.len > 0) alloc::free(mem, entry.ptr);
	if (edited.mask.len > 0) alloc::free(mem, edited.mask);
	edited.mask = alloc::new_array(mem, String, (sz)picked.len);
	foreach (usz i, name : picked) edited.mask[i] = name.copy(mem);
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

fn void anim_layer_mask_clear_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) return;
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	if (edited.mask.len == 0) { edited.free(mem); return; }
	foreach (entry : edited.mask) if (entry.len > 0) alloc::free(mem, entry.ptr);
	alloc::free(mem, edited.mask);
	edited.mask = {};
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

// ---------------------------------------------------------------------------
// The form

fn void layer_free_string(String* text) @local
{
	if (text.len > 0) alloc::free(mem, text.ptr);
	*text = "";
}

fn void anim_layer_named(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || text.len == 0 || !anim_can_rewrite(ui)) return;
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	if (edited.name == text) { edited.free(mem); return; }
	layer_free_string(&edited.name);
	edited.name = text.copy(mem);
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

fn void anim_layer_seed_submitted(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) return;
	uint? seed = text.to_uint();
	if (catch seed) { app.@notice("the seed is a whole number"); return; }
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	edited.seed = seed;
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

fn void anim_layer_mode_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) { refresh_animations_view(ui); return; }
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	edited.mode = index == 1 ? OVERRIDE : ADDITIVE;
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

fn void anim_layer_axis_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) { refresh_animations_view(ui); return; }
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	edited.axis = index == 0 ? (Vec3){ 1, 0, 0 } : (index == 1 ? (Vec3){ 0, 1, 0 } : (Vec3){ 0, 0, 1 });
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

// The nth joint of the rig the choosers list (unnamed ones are not listed).
fn String layer_joint_at(AppState* app, usz n) @local
{
	RigView? opened = app.open_rig(mem);
	if (catch opened) return "";
	RigView view = opened;
	defer view.free(mem);
	usz seen = 0;
	foreach (name : view.names)
	{
		if (name.len == 0) continue;
		if (seen++ == n) return name.tcopy();
	}
	return "";
}

fn void anim_layer_joint_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	String name = layer_joint_at(app, index);
	if (at < 0 || name.len == 0 || !anim_can_rewrite(ui)) { refresh_animations_view(ui); return; }
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	if (edited.joint == name) { edited.free(mem); return; }
	layer_free_string(&edited.joint);
	edited.joint = name.copy(mem);
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

// Entry 0 of the tip chooser is "follow the chain": no tip.
fn void anim_layer_tip_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) { refresh_animations_view(ui); return; }
	String name = index == 0 ? "" : layer_joint_at(app, index - 1);
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	if (edited.tip == name) { edited.free(mem); return; }
	layer_free_string(&edited.tip);
	if (name.len > 0) edited.tip = name.copy(mem);
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

<*
 Write one number of the active layer, landing it as one edit. Sliders commit
 once, when the pointer is released.
*>
fn void layer_set_number(Ui* ui, LayerParam param, float value) @private
{
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) { refresh_animations_view(ui); return; }
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	switch (param)
	{
		case WEIGHT: edited.weight = math::clamp(value, 0.0f, 1.0f);
		case AMPLITUDE: edited.amplitude = value * (float)math::PI / 180.0f;
		case CYCLES: edited.cycles = value;
		case LAG: edited.lag = value;
		case FALLOFF: edited.falloff = value;
		case PHASE: edited.phase = value;
		case AT: edited.at = value;
		case WIDTH: edited.width = value;
		case START: edited.start = value;
		case END: edited.end = value;
		case FADE_IN: edited.fade_in = value;
		case FADE_OUT: edited.fade_out = value;
	}
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

fn void anim_layer_weight_committed(Ui* ui, float value) => layer_set_number(ui, WEIGHT, value);
fn void anim_layer_amplitude_committed(Ui* ui, float value) => layer_set_number(ui, AMPLITUDE, value);
fn void anim_layer_cycles_committed(Ui* ui, float value) => layer_set_number(ui, CYCLES, value);
fn void anim_layer_lag_committed(Ui* ui, float value) => layer_set_number(ui, LAG, value);
fn void anim_layer_falloff_committed(Ui* ui, float value) => layer_set_number(ui, FALLOFF, value);
fn void anim_layer_phase_committed(Ui* ui, float value) => layer_set_number(ui, PHASE, value);
fn void anim_layer_at_committed(Ui* ui, float value) => layer_set_number(ui, AT, value);
fn void anim_layer_width_committed(Ui* ui, float value) => layer_set_number(ui, WIDTH, value);
fn void anim_layer_start_committed(Ui* ui, float value) => layer_set_number(ui, START, value);
fn void anim_layer_end_committed(Ui* ui, float value) => layer_set_number(ui, END, value);
fn void anim_layer_fade_in_committed(Ui* ui, float value) => layer_set_number(ui, FADE_IN, value);
fn void anim_layer_fade_out_committed(Ui* ui, float value) => layer_set_number(ui, FADE_OUT, value);
