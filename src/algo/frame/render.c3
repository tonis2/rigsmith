<* The pure half of src/mcp/render.c3: no state, undo or notices. *>
module crig;

import rig;
import std::collections::object;
import std::encoding::base64;
import std::math;

<*
 The most instants one call will photograph.

 Each one is a whole frame drawn, read back off the GPU and decoded, so this is a
 seconds-per-call limit rather than a memory one — and a sheet of more than
 sixteen tiles is past the point where any of them can be read anyway.
*>
const usz RENDER_MOST_FRAMES = 16;

// The longest edge the sheet is allowed to have. The same budget one screenshot
// gets, for the same reason: a client resamples anything larger down to about
// this before a model sees it.
const uint RENDER_MAX_EDGE = 1568;

// Never below this, however many tiles are asked for: a 40-pixel figure answers
// no question, and a caller that wanted sixteen of those wanted four.
const uint RENDER_MIN_TILE = 96;

const String SHEET_FILE = "rigsmith-mcp-render.png";

// The largest tile a frame without the interface is drawn at, whatever the
// sheet's budget would allow: past it a tile costs bytes and shows nothing new.
const uint RENDER_CLEAN_MOST = 1024;

<*
 How many tiles go in a row, when the caller did not say.

 Square-ish *sheets*, not square grids: a viewport is whatever shape the
 workspace left it, and four wide tiles in a row make a picture ten times wider
 than it is tall, which is illegible however many pixels it is given. Solving
 `columns · width ≈ rows · height` with `rows = frames / columns` gives
 `columns = √(frames · height / width)`.
*>
fn usz sheet_columns(usz frames, uint width, uint height)
{
	if (frames <= 1 || width == 0) return 1;
	double square = math::sqrt((double)frames * (double)height / (double)width);
	usz columns = (usz)math::max(1.0, math::round(square));
	return columns > frames ? frames : columns;
}

<*
 How big one tile is, so that the whole sheet fits the budget.

 Both directions are checked because a wide grid and a tall one run out of room
 on different edges, and a tile taken only from the width would make a
 one-column sheet of nine frames far taller than anything a client keeps.
*>
fn void tile_size(uint width, uint height, usz columns, usz rows, uint* out_width, uint* out_height)
{
	uint by_width = RENDER_MAX_EDGE / (uint)columns;
	uint by_height = (uint)((double)(RENDER_MAX_EDGE / (uint)rows) * (double)width / (double)height);

	uint tile = math::min(math::min(by_width, by_height), width);
	// The floor never reaches past the source: enlarging a tile past the pixels
	// that were drawn buys bytes and no detail, which is the same trade
	// `screenshot_content` refuses when it only ever scales down.
	if (tile < RENDER_MIN_TILE) tile = math::min(RENDER_MIN_TILE, width);

	*out_width = tile;
	// Rounded up, so neither side can land on zero however thin the window is.
	*out_height = (uint)math::max(1.0, math::ceil((double)tile * (double)height / (double)width));
}
