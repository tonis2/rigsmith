<* The pure half of src/app/capture.c3: no state, undo or notices. *>
module crig;

import std::collections::object;
import std::encoding::json;
import std::core::string;
import std::math;
import std::collections::list;

// A column of the divider is this dark, in this share of the picture's rows.
const uint DIVIDER_DARK = 80;

const float DIVIDER_ROWS = 0.9f;

// How far a divider may sit from its reference's, as a share of the width.
const float DIVIDER_SLACK = 0.006f;

// The middle of the columns dark from top to bottom in `rgba`, in the middle
// half of the picture; -1 when there are none.
fn sz divider_column(char[] rgba, uint width, uint height)
{
	sz first = -1;
	sz last = -1;
	for (uint x = width / 4; x < width - width / 4; x++)
	{
		uint dark = 0;
		for (uint y = 0; y < height; y++)
		{
			usz at = ((usz)y * width + x) * 4;
			if (((uint)rgba[at] + rgba[at + 1] + rgba[at + 2]) / 3 < DIVIDER_DARK) dark++;
		}
		if ((float)dark < DIVIDER_ROWS * (float)height) continue;
		if (first < 0) first = (sz)x;
		last = (sz)x;
	}
	return first < 0 ? -1 : (first + last) / 2;
}

<*
 Whether a picture's divider at `column` is where the layout puts it: the
 layout `layout_width` x `layout_height` split at `split`, scaled to cover
 the picture and centred, as the pipeline does.
*>
fn bool divider_fits(sz column, uint width, uint height, float layout_width, float layout_height, float split)
{
	float scale = math::max((float)width / layout_width, (float)height / layout_height);
	float crop = (layout_width * scale - (float)width) * 0.5f;
	return math::abs((float)column - (split * scale - crop)) <= DIVIDER_SLACK * (float)width;
}
