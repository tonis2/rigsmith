<* The pure half of src/app/key_spread.c3: no state, undo or notices. *>
module crig;

import std::math;
import rig;
import std::collections::list;
import std::sort;

<*
 Where a keyed pose edit goes; see the file's header.
*>
enum KeyReach
{
	FRAME,
	SELECTED_KEYS,
	WHOLE_CLIP,
}
