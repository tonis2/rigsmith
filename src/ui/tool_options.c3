<*
 The tool options strip: the running tool's settings as real controls, across
 the top of the 3D view. Only the weight brush has one — its size, its strength,
 which way a plain drag paints and whether it paints through the model (X-ray) —
 so painting needs no modifier and no held key. Ctrl-drag, ctrl+shift-drag, alt
 and F stay as accelerators.
*>
module crig;

import cui;
import cui::widgets;

const String BRUSH_OPTIONS_ID = "brush-options";
const String BRUSH_SIZE_ID = "brush-size";
const String BRUSH_STRENGTH_ID = "brush-strength";
const String BRUSH_MODE_ID = "brush-mode";
const String BRUSH_XRAY_ID = "brush-xray";

const float BRUSH_SLIDER_W = 200.0;

String[2] brush_mode_options = { "Add", "Remove" };

struct BrushOptions (Widget)
{
	bool had;
}

fn Element* BrushOptions.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.had = app.brushing;

	return @subtree(elem.ui)
	{
		@tree((Column) { })
		{
			if (self.had)
			{
				@tree(JOINT_PANEL_SURFACE)
				{
					@tree((Row) { .gap = JOINT_PANEL_GAP, .cross_align = CENTER })
					{
						@node((Label) { .text = "Weight brush", .size = 13.0f, .color = TEXT });
						@node((Slider) {
							.label = "Size",
							.suffix = " px",
							.value = app.brush_radius,
							.min = BRUSH_RADIUS_MIN,
							.max = BRUSH_RADIUS_MAX,
							.step = 1.0f,
							.on_change = &brush_size_moved,
							.style = SETTINGS_SLIDER_STYLE,
							.size = { BRUSH_SLIDER_W, 0 },
						}).with_id(BRUSH_SIZE_ID);
						// As a percentage: how far one stroke carries a vertex.
						@node((Slider) {
							.label = "Strength",
							.suffix = "%",
							.value = app.brush_strength * 100.0f,
							.min = BRUSH_STRENGTH_MIN * 100.0f,
							.max = BRUSH_STRENGTH_MAX * 100.0f,
							.step = 1.0f,
							.decimals = 0,
							.on_change = &brush_strength_moved,
							.style = SETTINGS_SLIDER_STYLE,
							.size = { BRUSH_SLIDER_W, 0 },
						}).with_id(BRUSH_STRENGTH_ID);
						@node((Segmented) { .options = brush_mode_options[..],
							.selected = app.brush_removes ? 1 : 0,
							.on_change = &brush_mode_chosen, .style = SEGMENTED_STYLE })
							.with_id(BRUSH_MODE_ID);
						// Saved in the config, unlike the size and strength.
						@node((Checkbox) { .label = "X-ray", .checked = app.config.brush_xray,
							.on_change = &brush_xray_toggled, .style = CHECKBOX_STYLE })
							.with_id(BRUSH_XRAY_ID);
					};
				};
			}
		};
	};
}

<*
 Appears and goes with the brush, and follows a size or mode changed by the
 keys (F, ctrl) without a rebuild.
*>
fn void BrushOptions.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (app.brushing != self.had)
	{
		elem.request_build();
		return;
	}
	if (!self.had) return;

	if (try Element* size = elem.find_id(BRUSH_SIZE_ID))
	{
		Slider* slider = size.widget_as(Slider);
		if (!slider.dragging && slider.value != app.brush_radius)
		{
			slider.value = app.brush_radius;
			size.request_paint();
		}
	}
	if (try Element* strength = elem.find_id(BRUSH_STRENGTH_ID))
	{
		Slider* slider = strength.widget_as(Slider);
		float percent = app.brush_strength * 100.0f;
		if (!slider.dragging && slider.value != percent)
		{
			slider.value = percent;
			strength.request_paint();
		}
	}
	if (try Element* mode = elem.find_id(BRUSH_MODE_ID))
	{
		Segmented* strip = mode.widget_as(Segmented);
		sz now = app.brush_removes ? 1 : 0;
		if (!strip.tracking && strip.selected != now)
		{
			strip.selected = now;
			mode.request_paint();
		}
	}
	if (try Element* xray = elem.find_id(BRUSH_XRAY_ID))
	{
		Checkbox* box = xray.widget_as(Checkbox);
		if (!box.held && box.checked != app.config.brush_xray)
		{
			box.checked = app.config.brush_xray;
			xray.request_paint();
		}
	}
}

fn void brush_size_moved(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.set_brush_radius(value)) app.refresh_ui();
}

fn void brush_strength_moved(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.set_brush_strength(value / 100.0f)) app.refresh_ui();
}

fn void brush_mode_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	app.brush_removes = index == 1;
	app.refresh_ui();
}

fn void brush_xray_toggled(Ui* ui, bool on)
{
	AppState* app = ui.inherit(AppState)!!;
	app.config.brush_xray = on;
	app.config.save();
	app.refresh_ui();
}
