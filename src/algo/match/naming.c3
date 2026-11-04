<* The pure half of src/app/naming.c3: no state, undo or notices. *>
module crig;



<*
 What an auto-naming did.

 `matched` against `total` is the coverage — how much of the plan the rig turned
 out to have — and is the pair worth showing. Both count the plan's *required*
 joints only; `extra` is the optional ones that matched as well, which on a biped
 means the fingers. `renamed` is smaller whenever a dot already carried the name
 the plan wanted, which is the ordinary result of running this twice.

 `plan` is borrowed from the pack that won, so it lives exactly as long as the
 library does: read it, print it, do not keep it across a rescan.
*>
struct AutoNaming
{
	String plan;
	usz matched;
	usz total;
	usz extra;    // optional plan joints that matched too — the fingers
	usz renamed;
	usz unnamed;  // dots the plan had no joint for, and so left alone
}

<*
 Whether the match was good enough to have been acted on.
*>
fn bool AutoNaming.usable(&self) => self.total > 0 && self.matched * 3 >= self.total * 2;
