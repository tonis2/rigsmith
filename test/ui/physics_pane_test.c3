module crig_tests::ui;
import crig;
import libc;
import cui;
import cui::widgets;
import c3w;
import rig;
import gltf;
import collision;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;

// ---------------------------------------------------------------------------
// The Motion & Physics pane: the panel secondary motion is tuned from, and the
// collision check is read from.
//
// Last in the file, with the area checks, and for their reason: every one of
// these switches a pane to another view, which rebuilds it and recycles the
// element pointers a check that ran after them would be holding.
//
// The gestures are real ones — a click on the tab, on the tick box, a drag along
// the slider's track — because the thing worth pinning is that a value found by
// dragging reaches the document, and nothing that calls the callbacks directly
// can see the drag land on the wrong widget.

// A chain the physics can own: hips at the root, a spine, and a tail below it,
// each one the parent of the next.
struct PhysicsRig
{
	uint hips;
	uint spine;
	uint tail;
}

fn PhysicsRig physics_rig(Fixture* fixture)
{
	PhysicsRig rig = {
		.hips = fixture.doc().add_dot({ 0, 0.4f, 0 }, "hips"),
		.spine = fixture.doc().add_dot({ 0, 0.0f, 0 }, "spine"),
		.tail = fixture.doc().add_dot({ 0, -0.4f, 0 }, "tail"),
	};
	fixture.doc().connect(rig.hips, rig.spine);
	fixture.doc().connect(rig.spine, rig.tail);
	fixture.app.refresh_ui();
	return rig;
}

// A chain from one dot to another, on the Tail preset, with the numbers the
// checks below read back.
fn crig::SecondaryChain physics_chain(uint root, uint tip, float flexibility = 0.4f, float damping = 0.7f)
{
	crig::SecondaryChain chain = (crig::SecondaryChain){ .root = root, .tip = tip }.with_preset(crig::SecondaryPreset.TAIL);
	chain.flexibility = flexibility;
	chain.damping = damping;
	return chain;
}

// Open the Physics pane on the single starting pane, and settle it.
fn bool show_physics_pane(Fixture* fixture)
{
	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip) return false;

	fixture.click(tab_center(fixture, strip, TAB_PHYSICS));
	fixture.ui.flush();

	Element*? panel = fixture.ui.find_id(crig::PHYSICS_PANEL_ID);
	return @ok(panel);
}

// The panel's controls are found by what they say rather than by position: a row
// added above one of them must not send every click in these checks one control
// down.
fn Element* physics_slider(Fixture* fixture, String label)
{
	Element* found = null;
	fixture.ui.@each(Slider; s)
	{
		if (!found && s.widget_as(Slider).label == label) found = s;
	};
	return found;
}

fn Element* physics_box(Fixture* fixture, String label)
{
	Element* found = null;
	fixture.ui.@each(Checkbox; b)
	{
		if (!found && b.widget_as(Checkbox).label == label) found = b;
	};
	return found;
}

// The middle of a control, which is on the track for a slider and on the box for
// a tick — both of which are what a pointer would land on.
fn Vec2 control_center(Element* elem) => elem.absolute + elem.size * 0.5f;

// A pixel on a slider's track, as a fraction along it. Derived from the widget's
// own geometry, so a restyled column moves the click with it.
fn Vec2 slider_pixel(Element* elem, float fraction)
{
	Slider* slider = elem.widget_as(Slider);
	Vec2 span = slider.track_span(elem);
	SliderStyle style = slider.style.resolved();
	float travel = span.y - style.handle_width;
	return elem.absolute + (Vec2) {
		span.x + style.handle_width * 0.5f + travel * fraction,
		elem.size.y * 0.5f,
	};
}

<*
 The pane offers the panel, and the panel says what it is for.

 The panel is a real view in the workspace's registry rather than a dialog, so
 the check that it exists is a check that the tab reached it — a view whose
 builder is never called is a tab that switches to an empty pane.
*>
fn void the_physics_pane_builds_its_panel() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the physics pane builds its panel");
	fixture.reset();

	physics_rig(fixture);
	test::@check(show_physics_pane(fixture), "the Physics tab did not build a panel");

	test::@check(physics_box(fixture, "Simulate") != null, "no Simulate box in the panel");
	test::@check(physics_box(fixture, "Secondary motion") != null, "no Secondary motion box in the panel");
	test::@check(physics_slider(fixture, "Flexibility") != null, "no Flexibility slider in the panel");
	test::@check(physics_slider(fixture, "Damping") != null, "no Damping slider in the panel");
	test::@check(physics_slider(fixture, "Gravity") != null, "no Gravity slider in the panel");
	test::@check(physics_box(fixture, "Collide with character") != null, "no Collide box in the panel");
	test::@check(@ok(fixture.ui.find_id(crig::PHYSICS_PRESET_ID)), "no Preset menu in the panel");
	test::@check(@ok(fixture.ui.find_id(crig::PHYSICS_STATUS_ID)), "no collision status line in the panel");

	// The old per-bone controls are gone, and so are the cone, the thickness
	// and the capsule: where a chain swings is the Joint card's limits, how
	// thick it is comes off its skin, and the capsule is behind Advanced.
	test::@check(physics_slider(fixture, "Stiffness") == null && physics_slider(fixture, "Cone") == null
		&& physics_slider(fixture, "Swing") == null && physics_slider(fixture, "Thickness") == null,
		"a Stiffness, Cone, Swing or Thickness slider is still on the panel");
	test::@check(physics_box(fixture, "Collider capsule") == null && physics_slider(fixture, "Radius") == null,
		"the capsule controls are in the ordinary workflow rather than behind Advanced");
	bool listed = false;
	fixture.ui.@each(Tree; t) { listed = true; };
	test::@check(!listed, "the owned-bone list is still on the panel");

	// Behind Advanced they are, though — for a rig with no mesh, or a KHR file.
	crig::physics_advanced_clicked(fixture.ui);
	fixture.ui.flush();
	test::@check(physics_box(fixture, "Collider capsule") != null && physics_slider(fixture, "Radius") != null,
		"opening Advanced did not offer the capsule");
	crig::physics_advanced_clicked(fixture.ui);
	fixture.ui.flush();
	test::@check(physics_box(fixture, "Collider capsule") == null, "closing Advanced left the capsule on the panel");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 Ticking Secondary motion gives the selected dot a chain, with its tip inferred
 and the Tail preset on it — and one Ctrl+Z hands it back.

 The inference matters as much as the tick: a chain rooted at the spine runs
 down through the tail, since the tail is the spine's only child, so one tick
 on the spine is the whole tail rather than one bone of it.
*>
fn void ticking_secondary_motion_gives_the_run_a_chain() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("ticking secondary motion gives the run a chain");
	fixture.reset();

	PhysicsRig rig = physics_rig(fixture);
	fixture.app.select(rig.spine);

	if (!show_physics_pane(fixture))
	{
		test::@check(false, "SKIPPED — the Physics tab did not build a panel");
		return;
	}

	Element* box = physics_box(fixture, "Secondary motion");
	if (!box)
	{
		test::@check(false, "SKIPPED — no Secondary motion box in the panel");
		return;
	}

	fixture.click(control_center(box));
	fixture.ui.flush();

	crig::SecondaryChain chain = fixture.doc().secondary_of(rig.spine);
	test::@check(chain.present(), "ticking Secondary motion left the bone the animation's");
	test::@check(chain.tip == rig.tail, "the chain ends at dot %d rather than at the tail below the spine", chain.tip);
	test::@check(chain.preset == crig::SecondaryPreset.TAIL, "it arrived on a preset other than Tail");
	test::@check(chain.flexibility == 0.4f && chain.damping == 0.7f && chain.gravity == 1.0f && chain.collide,
		"it arrived with values other than Tail's");
	test::@check(fixture.app.is_dynamic(rig.tail) && fixture.app.is_dynamic(rig.spine) && !fixture.app.is_dynamic(rig.hips),
		"the overlay does not see the run the chain owns");

	// Ticked from the middle of the run, the box shows the chain it is part of
	// and unticking takes that chain — not a bone of it — back.
	fixture.app.select(rig.tail);
	fixture.feed(VIEWPORT_CENTER);
	fixture.ui.flush();
	Element* again = physics_box(fixture, "Secondary motion");
	test::@check(again != null && again.widget_as(Checkbox).checked, "the box is unticked on a bone inside a chain");
	if (again)
	{
		fixture.click(control_center(again));
		fixture.ui.flush();
		test::@check(!fixture.doc().secondary_of(rig.spine).present(), "unticking from the tail did not take the spine's chain back");
		fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
		test::@check(fixture.doc().secondary_of(rig.spine).present(), "one Ctrl+Z did not bring the chain back");
	}

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(!fixture.doc().secondary_of(rig.spine).present(), "a second Ctrl+Z did not take the first tick back");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The root is refused, the way `set_secondary_motion` refuses it.

 `jiggle_specs_from_document` skips a chain on a joint with no parent above it
 — there is nothing for it to hang from — so a tick that took would be a chain
 that never moved, which is worse than a tick that does not.
*>
fn void the_root_cannot_start_a_chain() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the root cannot start a chain");
	fixture.reset();

	PhysicsRig rig = physics_rig(fixture);
	fixture.app.select(rig.hips);
	test::@check(fixture.doc().root_id == rig.hips, "the first dot placed was not the root");

	if (!show_physics_pane(fixture))
	{
		test::@check(false, "SKIPPED — the Physics tab did not build a panel");
		return;
	}

	Element* box = physics_box(fixture, "Secondary motion");
	if (!box)
	{
		test::@check(false, "SKIPPED — no Secondary motion box in the panel");
		return;
	}

	fixture.click(control_center(box));
	fixture.ui.flush();

	test::@check(!fixture.doc().secondary_of(rig.hips).present(), "the root was given a chain");
	test::@check(fixture.app.notice().len > 0, "and nothing said why");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 A drag along a slider writes through as it goes, and the release closes one undo
 step over the whole gesture.

 Both halves are the point of the control. Writing through is what makes a tail
 answer while the pointer is still down; one step is what makes a drag the user
 did not like one Ctrl+Z rather than two hundred.
*>
fn void dragging_a_slider_tunes_the_chain_in_one_undo_step() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("dragging a slider tunes the chain in one undo step");
	fixture.reset();

	PhysicsRig rig = physics_rig(fixture);
	fixture.app.set_secondary_recorded(physics_chain(rig.spine, rig.tail, 0.4f, 0.3f));
	fixture.app.undo_stack.commit();
	// Selected at the tail, so what is dragged is the chain the tail is part of.
	fixture.app.select(rig.tail);

	if (!show_physics_pane(fixture))
	{
		test::@check(false, "SKIPPED — the Physics tab did not build a panel");
		return;
	}

	Element* slider = physics_slider(fixture, "Damping");
	if (!slider)
	{
		test::@check(false, "SKIPPED — no Damping slider in the panel");
		return;
	}

	// Down at a quarter, across to three quarters, up: four frames, and the
	// document has to have moved on the way rather than at the end.
	fixture.feed(slider_pixel(slider, 0.25));
	fixture.feed(slider_pixel(slider, 0.25), left: true);
	float mid_drag = fixture.doc().secondary_of(rig.spine).damping;
	fixture.feed(slider_pixel(slider, 0.75), left: true);
	fixture.feed(slider_pixel(slider, 0.75));
	fixture.ui.flush();

	test::@check(math::abs(mid_drag - 0.25f) < 0.02f,
		"the press wrote %s where a quarter along the track is 0.25", mid_drag);

	float landed = fixture.doc().secondary_of(rig.spine).damping;
	test::@check(math::abs(landed - 0.75f) < 0.02f,
		"the drag left the damping at %s where three quarters along is 0.75", landed);

	// And the flexibility it was not dragging is untouched: the setter overwrites
	// rather than merges, so a callback that wrote its own field alone would have
	// cleared the rest.
	test::@check(fixture.doc().secondary_of(rig.spine).flexibility == 0.4f,
		"the drag cleared the flexibility it was not about");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	float undone = fixture.doc().secondary_of(rig.spine).damping;
	test::@check(math::abs(undone - 0.3f) < 0.001f,
		"one Ctrl+Z left the damping at %s rather than back at 0.3 — the drag was more than one step", undone);

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The pane says which chains the rig carries, and how the edited one's swing is
 bounded — by the Joint card's rotation limits, which it reports rather than
 edits.

 One line each, in place of the list the pane used to be: the overlay rings
 the dynamic dots, so what the pane owes is the names and the one thing a
 user cannot see on the overlay, which is why a tail will or will not fall.
*>
fn void the_pane_names_the_chains_and_reports_their_limits() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the pane names the chains and reports their limits");
	fixture.reset();

	PhysicsRig rig = physics_rig(fixture);
	fixture.app.set_secondary_recorded(physics_chain(rig.spine, rig.tail));
	fixture.app.undo_stack.commit();
	fixture.app.select(rig.spine);

	if (!show_physics_pane(fixture))
	{
		test::@check(false, "SKIPPED — the Motion & Physics tab did not build a panel");
		return;
	}

	test::@check(fixture.app.physics_summary.contains("1 chain") && fixture.app.physics_summary.contains("spine"),
		"the summary reads \"%s\" rather than naming the one chain by its root", fixture.app.physics_summary);
	test::@check(fixture.app.physics_swing_text.contains("freely"),
		"a chain with no limits on its joints reads \"%s\"", fixture.app.physics_swing_text);

	// A table on the spine, set the way the Joint card sets one: the line
	// follows without anything here being told, since a limit edit moves the
	// same generation a chain edit does.
	crig::JointRotationLimits limits = crig::unconstrained_rotation(rig.spine);
	limits.constrained = true;
	limits.axes[0] = { .allowed = true, .minimum = -0.3f, .maximum = 0.3f, .locked = 0.0f };
	test::@check(fixture.app.set_rotation_limits_recorded(rig.spine, limits), "the spine's table was refused");
	fixture.app.undo_stack.commit();
	fixture.feed(VIEWPORT_CENTER);
	fixture.ui.flush();
	test::@check(fixture.app.physics_swing_text.contains("1 of its 2 bones"),
		"with one of two bones limited the line reads \"%s\"", fixture.app.physics_swing_text);

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 A preset restarts the chain's values, the tip menu moves its end, and a capsule
 arrives at a quarter of its own bone.

 The three controls that exist because doing it by hand is the tedium the
 feature is for: nobody wants to find Hair's four numbers by dragging, and a
 chain that stops one bone short is one menu choice rather than a rebuild.
*>
fn void the_preset_the_tip_and_the_capsule_take_the_documented_values() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a preset, a tip and a capsule take the documented values");
	fixture.reset();

	PhysicsRig rig = physics_rig(fixture);
	fixture.app.select(rig.spine);
	fixture.app.set_secondary_recorded(physics_chain(rig.spine, rig.tail, 0.9f, 0.1f));
	fixture.app.undo_stack.commit();

	if (!show_physics_pane(fixture))
	{
		test::@check(false, "SKIPPED — the Physics tab did not build a panel");
		return;
	}

	// The preset, chosen through its own callback: a menu's rows are laid out by
	// cui, and what is worth pinning is that the row lands as the preset.
	crig::physics_preset_chosen(fixture.ui, (usz)crig::SecondaryPreset.HAIR);
	fixture.ui.flush();
	crig::SecondaryChain chain = fixture.doc().secondary_of(rig.spine);
	test::@check(chain.preset == crig::SecondaryPreset.HAIR && chain.flexibility == 0.55f && chain.damping == 0.6f,
		"choosing Hair left the chain at flexibility %s, damping %s (%s)", chain.flexibility, chain.damping, chain.preset);
	test::@check(chain.tip == rig.tail, "choosing a preset moved the tip");

	// The tip menu lists the dots below the root, in run order, and the chosen
	// row becomes the tip.
	test::@check(fixture.app.physics_tip_ids.len == 2 && fixture.app.physics_tip_ids[0] == rig.spine
		&& fixture.app.physics_tip_ids[1] == rig.tail,
		"the tip menu offers %d dots rather than the spine and the tail", fixture.app.physics_tip_ids.len);
	crig::physics_tip_chosen(fixture.ui, 0);
	fixture.ui.flush();
	test::@check(fixture.doc().secondary_of(rig.spine).tip == rig.spine, "choosing the spine as the tip did not shorten the chain");
	test::@check(!fixture.app.is_dynamic(rig.tail), "and the tail is still marked dynamic");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().secondary_of(rig.spine).tip == rig.tail, "one Ctrl+Z did not put the tip back");

	// The capsule, on the same bone, behind Advanced. The spine's bone runs to
	// the tail, which the rig above puts 0.4 away, so a quarter of it is 0.1.
	crig::physics_advanced_clicked(fixture.ui);
	fixture.ui.flush();
	Element* capsule = physics_box(fixture, "Collider capsule");
	if (!capsule)
	{
		test::@check(false, "SKIPPED — no collider box under Advanced");
		return;
	}

	fixture.click(control_center(capsule));
	fixture.ui.flush();

	float radius = fixture.doc().collider_of(rig.spine);
	test::@check(math::abs(radius - 0.1f) < 0.001f,
		"the capsule arrived at %s where a quarter of its 0.4 bone is 0.1", radius);

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The overlay's toggle is offered only when there is something to mark.

 The rule the tint views follow: an item that can be ticked on a rig where it
 shows nothing is one that reads as broken. What it controls is checked by the
 flag rather than by the pixels — the paint is projection arithmetic that
 `check_pick` already pins, and what is new here is only which colour it picks.
*>
fn void the_overlay_toggle_follows_what_the_physics_owns() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the overlay toggle follows what the physics owns");
	fixture.reset();

	PhysicsRig rig = physics_rig(fixture);

	test::@check(crig::query_show_physics(fixture.ui).disabled,
		"the overlay toggle is offered on a rig with nothing dynamic on it");

	fixture.app.set_secondary_recorded(physics_chain(rig.tail, rig.tail));
	fixture.app.undo_stack.commit();

	MenuItemFlags flags = crig::query_show_physics(fixture.ui);
	test::@check(!flags.disabled, "the toggle stayed greyed with a chain on the rig");
	test::@check(flags.checked, "the marks are off by default, so a chain shows nothing");
	test::@check(fixture.app.is_dynamic(rig.tail), "the overlay would not know the tail is dynamic");
	test::@check(!fixture.app.is_dynamic(rig.hips), "and thinks the hips are");

	crig::menu_show_physics(fixture.ui);
	test::@check(!fixture.app.show_physics, "the menu item did not turn the marks off");
	crig::menu_show_physics(fixture.ui);
	test::@check(fixture.app.show_physics, "or back on");
}

<*
 Every control the panel builds lands inside the pane, in order, without
 overlapping the one above it.

 The check a screenshot would be. A panel of stacked rows is exactly the shape
 that goes wrong quietly — a slider that fills the window rather than the column
 still paints, and a row that overflows the pane is clipped rather than reported
 — so what is asserted here is the geometry the eye would be checking: nothing
 wider than the pane, nothing on top of anything else, and the list between the
 two halves rather than under them.
*>
fn void the_panel_stacks_its_controls_inside_the_pane() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the panel stacks its controls inside the pane");
	fixture.reset();

	PhysicsRig rig = physics_rig(fixture);
	fixture.app.select(rig.tail);
	fixture.app.set_secondary_recorded(physics_chain(rig.tail, rig.tail));
	fixture.app.set_collider_recorded(rig.tail, 0.05f);
	fixture.app.undo_stack.commit();
	fixture.app.physics_advanced = true;

	if (!show_physics_pane(fixture))
	{
		test::@check(false, "SKIPPED — the Physics tab did not build a panel");
		return;
	}

	Element*? found = fixture.ui.find_id(crig::PHYSICS_PANEL_ID);
	if (catch found)
	{
		test::@check(false, "SKIPPED — no panel to measure");
		return;
	}
	Element* panel = found;

	// The pane the panel is in: everything below the window bar and the tab strip.
	float pane_right = crig::WIN_W;
	float pane_bottom = crig::WIN_H;

	test::@check(panel.absolute.x >= 0 && panel.absolute.x + panel.size.x <= pane_right + 0.5f,
		"the panel is %s wide at x=%s, which does not fit the pane",
		panel.size.x, panel.absolute.x);
	test::@check(panel.size.y > 0, "the panel came out with no height at all");

	// A column's worth, whatever the pane is. The starting pane is the whole
	// window, so a panel that took what it was offered would put every slider's
	// caption a screen away from its own number.
	test::@check(panel.size.x <= crig::PHYSICS_PANEL_W + 0.5f,
		"the panel took %s of a %s-wide pane rather than capping at %s",
		panel.size.x, pane_right, crig::PHYSICS_PANEL_W);

	// The sliders, in the order they are built — the capsule's last, under
	// Advanced. Each has to be inside the panel's own column and below the one
	// before it.
	String[4] captions = { "Flexibility", "Damping", "Gravity", "Radius" };
	float previous_bottom = panel.absolute.y;
	foreach (caption : captions)
	{
		Element* slider = physics_slider(fixture, caption);
		if (!slider)
		{
			test::@check(false, "no %s slider in the panel", caption);
			continue;
		}

		test::@check(slider.size.x > 0 && slider.size.y > 0,
			"the %s slider laid out to nothing (%s x %s)", caption, slider.size.x, slider.size.y);
		test::@check(slider.absolute.x >= panel.absolute.x - 0.5f
			&& slider.absolute.x + slider.size.x <= panel.absolute.x + panel.size.x + 0.5f,
			"the %s slider runs outside the panel's own column", caption);
		test::@check(slider.absolute.y >= previous_bottom - 0.5f,
			"the %s slider starts at %s, above the bottom of the control before it (%s)",
			caption, slider.absolute.y, previous_bottom);
		test::@check(slider.absolute.y + slider.size.y <= pane_bottom + 0.5f,
			"the %s slider hangs off the bottom of the window", caption);

		// The track has to be a real span, or the control is a caption and a number
		// with nothing to drag between them.
		Vec2 span = slider.widget_as(Slider).track_span(slider);
		test::@check(span.y > crig::PHYSICS_SLIDER_STYLE.handle_width,
			"the %s slider's track came out %s wide, which is narrower than its own handle", caption, span.y);

		previous_bottom = slider.absolute.y + slider.size.y;
	}

	// The collision check sits above the chain: what stops at the body, then
	// what moves on its own — the order the plan's pane reads in.
	Element*? status = fixture.ui.find_id(crig::PHYSICS_STATUS_ID);
	if (try status)
	{
		Element* flexibility = physics_slider(fixture, "Flexibility");
		if (flexibility)
		{
			test::@check(status.absolute.y < flexibility.absolute.y,
				"the collision status is below the sliders rather than above them");
		}
	}

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}

<*
 The panel follows a selection made anywhere else.

 The 3D view and this pane act on one selection and neither knows the other
 exists, so what keeps them together is the panel noticing per frame that the
 anchor moved — the HUD's own arrangement. Without it a user clicks the next bone
 in the viewport and tunes the previous one, which is the worst kind of wrong:
 every control still works, on the wrong subject.
*>
fn void the_panel_follows_the_selection_made_elsewhere() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the panel follows the selection made elsewhere");
	fixture.reset();

	PhysicsRig rig = physics_rig(fixture);
	fixture.app.set_secondary_recorded(physics_chain(rig.tail, rig.tail));
	fixture.app.undo_stack.commit();
	fixture.app.select(rig.tail);

	if (!show_physics_pane(fixture))
	{
		test::@check(false, "SKIPPED — the Physics tab did not build a panel");
		return;
	}

	Element* box = physics_box(fixture, "Secondary motion");
	if (!box)
	{
		test::@check(false, "SKIPPED — no Secondary motion box in the panel");
		return;
	}
	test::@check(box.widget_as(Checkbox).checked, "the box is unticked on a bone the physics owns");

	// The selection moves without the panel being touched — the shape of a click
	// in another pane, an undo, or an MCP call.
	fixture.app.select(rig.spine);
	fixture.feed(VIEWPORT_CENTER); // one frame, so `update` runs
	fixture.ui.flush();

	Element* after = physics_box(fixture, "Secondary motion");
	if (!after)
	{
		test::@check(false, "the panel lost its Secondary motion box on a rebuild");
		return;
	}
	test::@check(!after.widget_as(Checkbox).checked,
		"the box still reads the bone that was selected before");

	// And the caption with it, so the panel says which bone it is about.
	bool named = false;
	fixture.ui.@each(Label; l)
	{
		if (l.widget_as(Label).text == "spine") named = true;
	};
	test::@check(named, "the panel does not name the bone it is now tuning");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
}
