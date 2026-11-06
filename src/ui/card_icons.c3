<*
 The Weights card's icon buttons: a glyph in a tool-column cell, under a tooltip
 that says what it does.

 Blender's N-panel bargain. A row of named buttons and the paragraphs that
 explained them made the card taller than the view it floats in; a row of
 glyphs says the actions are there in a fifth of the room, and the words they
 had move into the tooltip, where they are read once and then out of the way.

 Composed like the tool column (`tool_column.c3`) and from its parts: cui's
 `Tooltip` around `tool_button`, with the glyph an SVG in assets/icons/card. A lit cell is
 a switch that is on (Mirror, the brush); a commit (Apply, Fix weights) keeps the
 plain cell and draws its glyph in the accent, so the two never read alike. An
 action with nothing to act on stays off the card rather than greyed — Clear and
 Invert appear once UV islands are being picked.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

// The SVGs' viewBox is the 30 px cell, drawn at its own size.
const float CARD_ICON_VIEW = 30.0;

// How a cell is drawn: see the file's comment.
enum CardCell
{
	PLAIN,
	LIT,
	COMMIT,
}

<* Each glyph carries its SVG, from assets/icons/card. *>
enum CardGlyph : (String svg)
{
	APPLY_GLYPH { $embed("../../assets/icons/card/apply.svg") },
	RESET_GLYPH { $embed("../../assets/icons/card/reset.svg") },
	MIRROR_GLYPH { $embed("../../assets/icons/card/mirror.svg") },
	BRUSH_GLYPH { $embed("../../assets/icons/card/brush.svg") },
	GROW_GLYPH { $embed("../../assets/icons/card/grow.svg") },
	SHRINK_GLYPH { $embed("../../assets/icons/card/shrink.svg") },
	CLEAR_GLYPH { $embed("../../assets/icons/card/clear.svg") },
	INVERT_GLYPH { $embed("../../assets/icons/card/invert.svg") },
	FIX_WEIGHTS_GLYPH { $embed("../../assets/icons/card/fix_weights.svg") },
	LASSO_GLYPH { $embed("../../assets/icons/card/lasso.svg") },
	// The Path toolbar's.
	PEN_GLYPH { $embed("../../assets/icons/card/pen.svg") },
	FROM_MOTION_GLYPH { $embed("../../assets/icons/card/from_motion.svg") },
	SLICE_GLYPH { $embed("../../assets/icons/card/slice.svg") },
	CLOSE_PATH_GLYPH { $embed("../../assets/icons/card/close_path.svg") },
	BAKE_GLYPH { $embed("../../assets/icons/card/bake.svg") },
	MUTE_GLYPH { $embed("../../assets/icons/card/mute.svg") },
	FOLLOW_GLYPH { $embed("../../assets/icons/card/follow.svg") },
	// The Joint card's.
	KEEP_ANGLE_GLYPH { $embed("../../assets/icons/card/keep_angle.svg") },
	// The Nodes pane's cards.
	RUN_GLYPH { $embed("../../assets/icons/card/run.svg") },
	STOP_GLYPH { $embed("../../assets/icons/card/stop.svg") },
	BROWSE_GLYPH { $embed("../../assets/icons/card/browse.svg") },
	COPY_GLYPH { $embed("../../assets/icons/card/copy.svg") },
	FOLDER_GLYPH { $embed("../../assets/icons/card/folder.svg") },
	SEED_GLYPH { $embed("../../assets/icons/card/seed.svg") },
	// The Pose tab's reference picture and its prompts.
	PICTURE_GLYPH { $embed("../../assets/icons/card/picture.svg") },
	VIDEO_PROMPT_GLYPH { $embed("../../assets/icons/card/video_prompt.svg") },
	IMAGE_PROMPT_GLYPH { $embed("../../assets/icons/card/image_prompt.svg") },
}

<*
 One icon button, inside the `@tree` building the card.

 @param glyph : `What the cell shows.`
 @param text : `The tooltip: what a click does, in a literal or a buffer that outlives the build.`
 @param on_click : `The action.`
 @param cell : `A switch that is on, a commit, or neither.`
 @param hint : `The keys line for the hint bar while the pointer is on the cell.`
 @return `The button, for with_id — a click on its centre is a click on the cell.`
*>
macro Element* @card_icon(CardGlyph glyph, String text, OnClick on_click, CardCell cell = PLAIN, String hint = "")
{
	// Dark ink on the lit cell, for the tool column's reason.
	Color ink = TEXT;
	if (cell == LIT) ink = DOT_OUTLINE;
	if (cell == COMMIT) ink = ACCENT;
	return widgets::@icon_button(glyph.svg, text, tool_button({ .checked = cell == LIT }, on_click), ink, CARD_ICON_VIEW, hint);
}
