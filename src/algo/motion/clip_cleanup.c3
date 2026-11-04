<* The pure half of src/app/clip_cleanup.c3: no state, undo or notices. *>
module crig;

import std::math;

<*
 What to take out of a clip. Translation holds the hips over where the clip
 starts and rotation takes off its net turn, as `RootMotionPolicy` does it;
 `on_root` carries them onto the root joint instead of discarding them.
*>
struct ClipCleanup
{
	bool translation;
	bool rotation;
	bool jitter;
	bool on_root;
}

fn bool ClipCleanup.asks(self) => self.translation || self.rotation || self.jitter;

fn bool ClipCleanup.moves(self) => self.translation || self.rotation;
