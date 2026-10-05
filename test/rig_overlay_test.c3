module crig_tests::rig_overlay;

import crig;
import cui;
import std::math;
import std::core::test;

fn void depth_fading_preserves_selected_and_hidden_controls() @test
{
	float near = crig::rig_overlay_opacity(2, 2, 4, false, false, 1.0f);
	float far = crig::rig_overlay_opacity(4, 2, 4, false, false, 1.0f);
	float hidden = crig::rig_overlay_opacity(4, 2, 4, true, false, 1.0f);
	test::@check(near > far && far > hidden && hidden > 0);
	test::eq(crig::rig_overlay_opacity(4, 2, 4, true, true, 0.1f), 1.0f);
	test::eq(crig::rig_overlay_opacity(2, 2, 2, false, false, 1.0f), near);
	// Translating the camera-relative depths does not alter visibility.
	test::eq(crig::rig_overlay_opacity(14, 12, 14, false, false, 1.0f), far);
	// Strength scales ordinary controls but never defeats either depth cue.
	test::eq(crig::rig_overlay_opacity(2, 2, 4, false, false, 0.5f), near * 0.5f);
	test::@check(crig::rig_overlay_opacity(4, 2, 4, true, false, 0.5f) < far * 0.5f);
}

fn void fading_changes_alpha_not_mesh_obscuring_rgb() @test
{
	Color ink = crig::rig_overlay_ink((Color){ 0.2, 0.4, 0.6, 1.0 }, 0.25);
	Vec4 rgba = (Vec4)ink;
	test::eq(rgba.x, 0.2f);
	test::eq(rgba.y, 0.4f);
	test::eq(rgba.z, 0.6f);
	test::eq(rgba.w, 0.25f);
}
