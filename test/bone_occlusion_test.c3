<*
 A bone that runs from inside the body out past its far wall fades where
 another part of the body stands in front of it, not along its whole length,
 and what is behind the skin is a faint trace rather than a second rig over the
 first.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::a_bone`
*>
module crig_tests::ui;

import crig;
import cui;
import std::core::test;
import std::math;

<*
 A second bone just behind the cube's front face owns that face, so the skin in
 front of the far piece is another limb's — the far hand seen through the near
 one — while the piece inside the cube has only its own depth of body in front.

 *Re-introduce:* test one point per bone again, and the bone comes out in a
 single opacity; or put `OCCLUDED_DIM` back near a half, and the hidden piece
 is no longer faint.
*>
fn void a_bone_fades_only_where_it_runs_behind_the_body() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();

	// Straight down +Z, so the cube's far wall stands between the eye and
	// everything past z = -1.
	f.app.camera.snap_to(crig::ViewAxis.POS_Z);
	for (uint i = 0; i < 1000 && f.app.camera.advance(DT); i++)
	{
	}

	f.app.doc.auto_connect = true;
	f.app.place({ -0.5, 0, 0 });
	f.app.place({ 0.5, 0, -1.8 });
	f.app.selected = 0;
	f.app.place({ -0.6, 0.5, 0.9 });
	f.app.place({ 0.6, 0.5, 0.9 });
	test::@check(f.app.doc.edges.len() == 2, "the two bones were not two edges");
	f.app.refresh_ui();
	f.feed(VIEWPORT_CENTER);

	Vec4 bone = (Vec4)crig::BONE;
	float strength = crig::effective_rig_overlay_strength(&f.app);
	usz faint;
	usz clear;
	foreach (drawing : f.ui.canvas.drawings.array_view())
	{
		if (drawing.kind != DrawingKind.LINE) continue;
		Vec4 ink = drawing.color;
		if (ink.x != bone.x || ink.y != bone.y || ink.z != bone.z) continue;
		float opacity = ink.w / (bone.w * strength);
		if (opacity <= 0.8f * crig::OCCLUDED_DIM + 0.001f)
		{
			faint++;
		}
		else
		{
			clear++;
		}
	}
	test::@check(faint > 0, "no piece of the bone past the far wall was faded");
	test::@check(clear > crig::BONE_PIECES, "the piece inside the body was faded with the rest");
	test::@check(crig::OCCLUDED_DIM < 0.2f, "what is behind the skin keeps %f of its ink", crig::OCCLUDED_DIM);
}
