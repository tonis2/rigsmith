<*
 A few characters drawn straight into an image's pixels, for `render`'s tiles.

 The UI's text goes through the GPU and cannot reach a picture assembled on the
 CPU, and a contact sheet whose tiles say nothing has to be read against its
 caption — count along, count down, look the number up. A label in the corner
 of each tile is read where the pose is. Five rows of three pixels each is
 enough for the only things a tile ever says: a key number and a time.
*>
module crig;

import image;

const uint LABEL_GLYPH_WIDTH @local = 3;
const uint LABEL_GLYPH_HEIGHT @local = 5;

// One row per entry, top to bottom; bit 2 is the leftmost pixel.
const char[5][10] LABEL_DIGITS @local = {
	{ 0b111, 0b101, 0b101, 0b101, 0b111 },
	{ 0b010, 0b110, 0b010, 0b010, 0b111 },
	{ 0b111, 0b001, 0b111, 0b100, 0b111 },
	{ 0b111, 0b001, 0b111, 0b001, 0b111 },
	{ 0b101, 0b101, 0b111, 0b001, 0b001 },
	{ 0b111, 0b100, 0b111, 0b001, 0b111 },
	{ 0b111, 0b100, 0b111, 0b101, 0b111 },
	{ 0b111, 0b001, 0b001, 0b001, 0b001 },
	{ 0b111, 0b101, 0b111, 0b101, 0b111 },
	{ 0b111, 0b101, 0b111, 0b001, 0b111 },
};
const char[5] LABEL_DOT @local = { 0, 0, 0, 0, 0b010 };
const char[5] LABEL_K @local = { 0b100, 0b101, 0b110, 0b101, 0b101 };
const char[5] LABEL_S @local = { 0, 0b111, 0b110, 0b011, 0b111 };
const char[5] LABEL_BLANK @local = { 0, 0, 0, 0, 0 };

// Anything the font does not have draws as a space, which leaves the label the
// width it was measured at.
fn char[5] label_glyph(char c) @local
{
	switch (c)
	{
		case '0'..'9': return LABEL_DIGITS[c - '0'];
		case '.': return LABEL_DOT;
		case 'k': return LABEL_K;
		case 's': return LABEL_S;
		default: return LABEL_BLANK;
	}
}

<*
 Write `text` into `img` with its box's top-left corner at x, y: white glyphs on
 the picture darkened to a quarter, so it reads over a pale floor and a dark
 background alike. Each glyph pixel is `scale` pixels square. Whatever falls
 past the image's edge is left out; an image deeper than eight bits a channel is
 left alone.
*>
fn void draw_label(image::Image* img, uint x, uint y, uint scale, String text)
{
	if (text.len == 0 || scale == 0 || img.bit_depth != 8) return;

	uint advance = (LABEL_GLYPH_WIDTH + 1) * scale;
	uint pad = scale;
	uint box_width = (uint)text.len * advance - scale + 2 * pad;
	uint box_height = LABEL_GLYPH_HEIGHT * scale + 2 * pad;

	for (uint row = 0; row < box_height; row++)
	{
		for (uint col = 0; col < box_width; col++)
		{
			label_paint(img, x + col, y + row, false);
		}
	}

	foreach (i, c : text)
	{
		char[5] glyph = label_glyph(c);
		uint left = x + pad + (uint)i * advance;
		for (uint gy = 0; gy < LABEL_GLYPH_HEIGHT; gy++)
		{
			for (uint gx = 0; gx < LABEL_GLYPH_WIDTH; gx++)
			{
				if (!(glyph[gy] & (1 << (LABEL_GLYPH_WIDTH - 1 - gx)))) continue;
				for (uint sy = 0; sy < scale; sy++)
				{
					for (uint sx = 0; sx < scale; sx++)
					{
						label_paint(img, left + gx * scale + sx, y + pad + gy * scale + sy, true);
					}
				}
			}
		}
	}
}

// One pixel: white and opaque for ink, a quarter of itself for the box. Alpha
// is the last channel when there is one and is never darkened, or the box would
// punch a hole through the picture.
fn void label_paint(image::Image* img, uint x, uint y, bool ink) @local
{
	if (x >= img.width || y >= img.height) return;

	usz bytes = (usz)img.bytes_per_pixel();
	bool alpha = img.format == image::PixelFormat.RGBA || img.format == image::PixelFormat.GRAYSCALE_ALPHA;
	usz colour = alpha ? bytes - 1 : bytes;
	usz at = ((usz)y * (usz)img.width + (usz)x) * bytes;

	for (usz c = 0; c < colour; c++)
	{
		img.pixels[at + c] = ink ? 255 : img.pixels[at + c] / 4;
	}
	if (alpha && ink) img.pixels[at + colour] = 255;
}
