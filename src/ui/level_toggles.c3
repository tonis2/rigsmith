<*
 The level's view switch, at the right of a 3D view's header: one cell that draws
 the level's colliders. It is there only while a level is open, so a scene with
 none has the header it always had.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const String LEVEL_STRIP_ID = "level-view";

IconStripCell[1] level_cells = {
	{ &query_show_colliders, &menu_show_colliders, "Level colliders — draw the shapes the ground is read from" },
};

fn IconStrip level_icon_strip()
{
	return { .cells = level_cells[..], .paint_icon = &paint_level_icon, .on_press = &close_menus, .style = view_strip_style() };
}

fn void paint_level_icon(Painter* painter, usz cell, Vec2 centre, Color ink, Color ground)
{
	painter.icon(centre, STRIP_ICON_VIEW, ICON_COLLIDERS, ink);
}

<* Empty without a level; the strip after the header's own gap with one. *>
struct LevelStrip (Widget)
{
	bool shown;
}

fn Element* LevelStrip.build(&self, Element* elem) @dynamic
{
	self.shown = elem.inherit(AppState)!!.has_level();
	return @subtree(elem.ui)
	{
		// The header's gap before the strip, which a Row would add even with nothing in it.
		@tree((Padding) { .insets = { .left = self.shown ? STAGE_SWITCH_GAP : 0 } })
		{
			if (self.shown)
			{
				@tree(widgets::tip_probe(&widgets::icon_strip_tip)) { @node(level_icon_strip()).with_id(LEVEL_STRIP_ID); };
			}
		};
	};
}

fn void LevelStrip.update(&self, Element* elem, float dt) @dynamic
{
	if (self.shown != elem.inherit(AppState)!!.has_level()) elem.request_build();
}
