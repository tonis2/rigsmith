<*
 The Motion & Physics pane: what moves on its own and what stops at the body.

 	the Motion & Physics tab, beside 3D View and Assets

 Three things share it, stated separately because they act differently — the
 plan's reading, and the reason the pane is one column and not three:

 - **Prevent intersections**, the self-collision check over the character's
   deformed skin (C5): one switch, a status line for the two states that are
   not simply "on", and the Advanced dialog behind a button.
 - **Secondary motion**, a behaviour on the chain the selected dot is part
   of: a preset, three sliders and a switch. Where the chain may *swing* is
   the Joint card's rotation limits and is only summarised here; how thick it
   is comes off its skin and is not a number at all.
 - **Animation**: whether the chains simulate under the playing clip, and the
   bake that writes what they did into a clip of their own.

 Secondary motion is a thing you arrive at rather than a thing you know: a
 flexibility is right when the tail reads as heavy, and nobody can say in
 advance which number that is. So every value here is on a slider and every
 slider writes through on the way past — the clip goes on playing, the sim is
 rebuilt on the next frame, and the tail answers while the pointer is still
 down. Typing 0.4 into a box and pressing enter is the same edit and a worse way
 to find it.

 **What the panel edits is the chain the selected dot is part of.** A chain is
 a root and a tip and the run between them, and clicking any bone of a tail
 shows the tail's behaviour: the rig's selection already lives on the AppState,
 so the 3D view and this pane are looking at the same bone without either of
 them saying so, and `AppState.secondary_root_of` says which chain that bone
 belongs to. Which dots carry chains is the overlay's to show, ringed in the
 physics colour, and one line here to say.

 **A drag is one undo step, not one per pixel.** `Slider.on_change` writes the
 document — that is what makes the tail move — and `Slider.on_commit`, which
 fires once when the button comes up, is what closes the group.
 `set_secondary_recorded` chains its entries until something commits, so the
 whole gesture goes back with one Ctrl+Z.

 **The rebuild is structural only.** `update` diffs which chain is being
 edited and what shape it has — its root, tip, preset and whether it collides
 — never the slider values: a rebuild releases the element the pointer is
 dragging, so a panel that rebuilt on every value would cut every drag short
 after one pixel.

 **Advanced** is where the old model's one remaining control lives: a collider
 capsule on the selected bone, for a rig with no mesh to be held off or a KHR
 runtime that wants one written, and the clear-all. Closed by default, since
 the ordinary rig needs neither.
*>
module crig;

import cui;
import cui::widgets;
import rig;
import std::math;

const String PHYSICS_PANEL_ID = "physics-panel";
const String PHYSICS_PRESET_ID = "physics-preset";
const String PHYSICS_TIP_ID = "physics-tip";
const String PHYSICS_PREVENT_ID = "physics-prevent-intersections";
const String PHYSICS_STATUS_ID = "physics-collision-status";
const String PHYSICS_ADVANCED_ID = "physics-advanced";

const float PHYSICS_PAD = 10.0;
const float PHYSICS_GAP = 8.0;

// Gravity runs below zero because a negative multiplier floats a chain upward,
// which is how a balloon, a flame or hair underwater is described. Four g is
// past anything that still reads as weight rather than as a snap.
const float PHYSICS_MIN_GRAVITY = -2.0;
const float PHYSICS_MAX_GRAVITY = 4.0;

// A capsule's radius as a fraction of the rig's size, so the same track means
// the same sleeve on a mouse and on an elephant.
const float PHYSICS_MAX_RADIUS_SHARE = 0.2;

// The preset a chain ticked on from the panel starts at: the same one
// set_secondary_motion starts a chain at, so a chain made here behaves exactly
// like one made by an agent.
const SecondaryPreset PHYSICS_UI_PRESET = TAIL;

// The preset menu, in the enum's own order so a row index is a preset.
String[5] physics_preset_options = { "Hair", "Tail", "Ear", "Soft accessory", "Custom" };

// ---------------------------------------------------------------------------
// The menus and the lines

<*
 Rebuild what the pane borrows: the tip menu of the chain being edited, the
 line that says which chains the rig carries, and the one that says how the
 edited chain's swing is bounded.

 Held on the AppState rather than beside the panel for the reason
 `category_rows` is: a `Select` borrows its labels for the life of its
 element, and a pane rebuilds its widgets from nothing when it splits or
 changes tab. Anything that deletes a dot has to rebuild these before the
 pane is drawn again — which the panel's own `update` does, since a dot
 count is part of what it diffs.
*>
fn void AppState.refresh_physics_menus(&self)
{
	self.free_physics_menus();
	self.physics_summary = self.physics_summary_text();

	uint root = self.secondary_root_of(self.selected);
	if (root == 0) return;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);

	self.refresh_physics_tips(&view, root);
	self.physics_swing_text = self.physics_swing_line(&view, self.doc.secondary_of(root));
}

fn void AppState.free_physics_menus(&self)
{
	if (self.physics_tip_options.len > 0) alloc::free(mem, self.physics_tip_options);
	if (self.physics_tip_ids.len > 0) alloc::free(mem, self.physics_tip_ids);
	self.physics_tip_options = {};
	self.physics_tip_ids = {};
	if (self.physics_summary.len > 0) alloc::free(mem, self.physics_summary.ptr);
	self.physics_summary = {};
	if (self.physics_swing_text.len > 0) alloc::free(mem, self.physics_swing_text.ptr);
	self.physics_swing_text = {};
}

// Which chains the rig carries, by their roots' names: the one line that
// stands in for the list the pane used to be. Owned by the caller.
fn String AppState.physics_summary_text(&self)
{
	usz chains = (usz)self.doc.secondary.len();
	if (chains == 0) return "no chain has secondary motion yet".copy(mem);

	DString out = dstring::new(mem);
	defer out.free();
	out.appendf("%d chain%s: ", chains, chains == 1 ? "" : "s");
	foreach (usz i, chain : self.doc.secondary.array_view())
	{
		if (i > 0) out.append_string(", ");
		Dot* root = self.doc.find(chain.root);
		out.append_string(root && root.name.len > 0 ? root.name : "unnamed");
	}
	return out.copy_str(mem);
}

<*
 How the edited chain's swing is bounded — by its joints' rotation limits,
 which the Joint card edits and this pane only reports. Owned by the caller.

 The one sentence the plan asked the pane to carry about limits: the cone
 the old model had is gone, the tables are the rig's, and a chain whose joints
 carry none swings wherever the animation and gravity take it.
*>
fn String AppState.physics_swing_line(&self, RigView* view, SecondaryChain chain)
{
	if (!chain.present()) return {};

	usz[] run = alloc::new_array(mem, usz, (sz)view.len());
	defer alloc::free(mem, run);
	usz length = self.secondary_run_of(view, chain, run);
	if (length == 0) return "the chain does not resolve on this rig — pick a tip below its root".copy(mem);

	usz limited = 0;
	for (usz i = 0; i < length; i++)
	{
		JointRotationLimits table = self.doc.rotation_limits_of(view.dot_ids[run[i]]);
		if (table.constrained && joint_limit_frame(&view.skeleton, view.dot_ids, table).usable()) limited++;
	}

	if (limited == 0)
	{
		return "swings freely — rotation limits on its joints, set in the Joint card, would bound it".copy(mem);
	}
	if (limited == length)
	{
		return string::format(mem, "swing bounded by the rotation limits on its %d bone%s", length, length == 1 ? "" : "s");
	}
	return string::format(mem, "swing bounded by rotation limits on %d of its %d bones", limited, length);
}

<*
 The dots a chain rooted at `root` could end at: every joint below it, depth
 first, so a menu reads as the run does.
*>
fn void AppState.refresh_physics_tips(&self, RigView* view, uint root)
{
	sz root_joint = view.joint_of(root);
	if (root_joint < 0) return;

	usz joints = view.len();
	usz[] order = alloc::new_array(mem, usz, (sz)joints);
	defer alloc::free(mem, order);
	usz[] stack = alloc::new_array(mem, usz, (sz)joints);
	defer alloc::free(mem, stack);

	// Depth first from the root, children in reverse index order so the
	// lower-numbered branch comes out first — the order the skeleton was built in.
	usz found = 0;
	usz depth = 0;
	stack[depth++] = (usz)root_joint;
	while (depth > 0)
	{
		usz at = stack[--depth];
		order[found++] = at;
		for (usz c = joints; c-- > 0;)
		{
			int parent = view.skeleton.parents[c];
			if (parent >= 0 && (usz)parent == at && depth < joints) stack[depth++] = c;
		}
	}

	self.physics_tip_options = alloc::new_array(mem, String, (sz)found);
	self.physics_tip_ids = alloc::new_array(mem, uint, (sz)found);
	for (usz i = 0; i < found; i++)
	{
		usz joint = order[i];
		self.physics_tip_ids[i] = view.dot_ids[joint];
		self.physics_tip_options[i] = view.names[joint].len > 0 ? view.names[joint] : "unnamed";
	}
}

<*
 How big this rig is, for the capsule slider measured in model units.

 The dots rather than the mesh, and the widest span rather than the height: a
 rig is placed before a body is built around it, and a tail laid along Z is as
 much of a rig as a figure standing up in Y. Falls back to the mesh for a
 document whose dots are all in one place, and to 1 for one with neither — a
 slider with a zero range is one that cannot be moved off zero.
*>
fn float AppState.physics_scale(&self)
{
	Vec3 low;
	Vec3 high;
	bool seen = false;

	foreach (dot : self.doc.dots.array_view())
	{
		if (!seen) { low = dot.position; high = dot.position; seen = true; continue; }
		low = { math::min(low.x, dot.position.x), math::min(low.y, dot.position.y), math::min(low.z, dot.position.z) };
		high = { math::max(high.x, dot.position.x), math::max(high.y, dot.position.y), math::max(high.z, dot.position.z) };
	}

	float span = 0.0f;
	if (seen)
	{
		Vec3 size = high - low;
		span = size.max();
	}

	if (span <= 0.0f)
	{
		rig::Bounds box = self.geometry.bounds();
		Vec3 size = box.max - box.min;
		span = size.max();
	}

	return span > 0.0f ? span : 1.0f;
}

// ---------------------------------------------------------------------------
// The view

<*
 Build the Motion & Physics pane: the panel in a scroll, since a short pane
 still has to reach the buttons under the sliders.
*>
fn Element* build_physics_view(Ui* ui)
{
	return @subtree(ui)
	{
		@tree((Scroll) { })
		{
			@tree((Padding) { .insets = widgets::insets_all(PHYSICS_PAD) })
			{
				@node((PhysicsPanel) { }).with_id(PHYSICS_PANEL_ID);
			};
		};
	};
}

<*
 Rebuild the panel in place.

 Called after anything that changes what the panel *offers* rather than what a
 slider holds — a chain made, a row selected, a drag committed. Never from a
 slider's live callback: the rebuild releases the element under the pointer,
 and the drag would end on its first pixel.
*>
fn void refresh_physics_panel(Ui* ui)
{
	if (try Element* panel = ui.find_id(PHYSICS_PANEL_ID)) panel.request_build();
}

<*
 What decides the shape of the panel, as opposed to the values in it.

 Deliberately without the slider values: they change on every pixel of a drag,
 and a rebuild mid-drag is a drag that stops. What is here is everything that
 changes which controls exist, whether they are live, and what the lines say
 — including a stamp over the rotation-limit rows, so a table switched on in
 the Joint card changes the swing line here without the card knowing.
*>
struct PhysicsSnapshot
{
	uint selected;
	usz dots;
	usz chains;
	usz capsules;
	uint root; // the chain the selected dot is part of, 0 for none
	uint tip;
	SecondaryPreset preset;
	bool collide;
	bool capsule; // whether the selected dot carries one
	bool simulating;
	bool animating;
	bool checking;   // the self-collision system is switched on
	bool preventing; // and blocking for this rig
	bool status;     // the status line has something to say
	bool contacts;
	bool advanced;
	usz limits;
}

fn PhysicsSnapshot physics_snapshot(AppState* app) @private
{
	uint root = app.secondary_root_of(app.selected);
	SecondaryChain chain = app.doc.secondary_of(root);
	return {
		.selected = app.selected,
		.dots = (usz)app.doc.dots.len(),
		.chains = (usz)app.doc.secondary.len(),
		.capsules = (usz)app.doc.colliders.len(),
		.root = root,
		.tip = chain.tip,
		.preset = chain.preset,
		.collide = chain.collide,
		.capsule = app.doc.collider_of(app.selected) > 0.0f,
		.simulating = app.sim_enabled,
		.animating = app.animating,
		.checking = app.config.self_collision,
		.preventing = !app.doc.allow_intersections,
		.status = collision_status_shown(app),
		.contacts = app.show_collision_contacts,
		.advanced = app.physics_advanced,
		.limits = physics_limits_stamp(app),
	};
}

// A stamp over what the swing line reads of the limit rows: which joints
// carry one, whether it is on, and what decides its frame. The numbers in a
// table are not in it — they change nothing the line says — so the Joint
// card's own drags do not rebuild this pane.
fn usz physics_limits_stamp(AppState* app) @private
{
	usz stamp = (usz)app.doc.rotation_limits.len();
	foreach (limits : app.doc.rotation_limits.array_view())
	{
		stamp = stamp * 31 + (usz)limits.dot_id * 7 + (limits.constrained ? (usz)3 : (usz)0)
			+ (usz)limits.primary_child * 5 + (limits.has_saved_frame ? (usz)1 : (usz)0);
	}
	return stamp;
}

fn bool PhysicsSnapshot.differs(self, PhysicsSnapshot other)
{
	return self.selected != other.selected
		|| self.dots != other.dots
		|| self.chains != other.chains
		|| self.capsules != other.capsules
		|| self.root != other.root
		|| self.tip != other.tip
		|| self.preset != other.preset
		|| self.collide != other.collide
		|| self.capsule != other.capsule
		|| self.simulating != other.simulating
		|| self.animating != other.animating
		|| self.checking != other.checking
		|| self.preventing != other.preventing
		|| self.status != other.status
		|| self.contacts != other.contacts
		|| self.advanced != other.advanced
		|| self.limits != other.limits;
}

struct PhysicsPanel (Widget)
{
	// What the last build reflected. `update` diffs against it rather than
	// against the document, so the panel follows a selection made in the 3D view
	// without anything there knowing this pane exists.
	//
	// Deliberately not named `size`: a zero `Vec2 size` is cui's fill-the-parent
	// convention, and this panel's width is its own decision — see `layout`.
	PhysicsSnapshot shown;
}

<*
 As wide as a column of controls should be, and no wider.

 A pane is whatever the user dragged it to, and this one opens full-window. A
 slider that took all of it would put its caption at one edge of the screen and
 its number at the other, with fourteen hundred pixels of track between them —
 every value legible and none of them readable together, which is the opposite of
 what a stack of related numbers is for. So the panel takes a column's worth and
 leaves the rest, the way a properties panel does everywhere else.

 Narrower panes get the pane instead: a fixed width in a pane too small for it
 would be a panel with its numbers cut off rather than a panel that fits.
*>
const float PHYSICS_PANEL_W = 400.0;

fn Vec2 PhysicsPanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });

	float width = math::min(PHYSICS_PANEL_W, constraints.max.x);
	Vec2 inner = elem.layout_child(0, cui::loose({ width, constraints.max.y }));
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ width, inner.y });
}

fn void PhysicsPanel.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	PhysicsSnapshot now = physics_snapshot(app);
	if (!now.differs(self.shown)) return;

	self.shown = now;
	elem.request_build();
}

fn Element* PhysicsPanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	app.refresh_physics_menus();

	// Taken here as well as in `update`, so the first frame after a build does not
	// find a stale snapshot and ask for the build it has just had.
	self.shown = physics_snapshot(app);

	uint id = app.selected;
	Dot* dot = app.doc.find(id);
	SecondaryChain chain = app.doc.secondary_of(self.shown.root);
	bool owned = chain.present();
	float capsule = app.doc.collider_of(id);
	float scale = app.physics_scale();

	// A dot with nothing selected still draws the whole editor, greyed: a panel
	// whose lower half appears and disappears with the selection is one whose
	// buttons move under the pointer.
	bool live = dot != null;

	usz tip_row = app.physics_tip_options.len;
	foreach (usz i, held : app.physics_tip_ids)
	{
		if (held == chain.tip) tip_row = i;
	}

	return @subtree(elem.ui)
	{
		@tree((Column) { .gap = PHYSICS_GAP })
		{
			// ---- what stops at the body ----
			@node((Label) {
				.text = "Motion & Physics",
				.size = FILE_HEADING_SIZE,
				.color = TEXT,
			});

			if (app.config.self_collision)
			{
				@node((Checkbox) {
					.label = "Prevent intersections",
					.checked = !app.doc.allow_intersections,
					.on_change = &physics_prevent_toggled,
					.style = CHECKBOX_STYLE,
				}).with_id(PHYSICS_PREVENT_ID);

				// The line the check has to say for itself — only for the two
				// states that are not simply "on", the way the Animations pane
				// reads it; a check that is working says "ready".
				if (collision_status_shown(app))
				{
					@node(collision_status_line()).with_id(PHYSICS_STATUS_ID);
				}
				else
				{
					@node((Label) {
						.text = "Collision status: ready",
						.size = LABEL_SIZE,
						.color = TEXT_DIM,
					}).with_id(PHYSICS_STATUS_ID);
				}

				@node(
					(Row) { .gap = PHYSICS_GAP, .cross_align = CENTER },
					(Checkbox) {
						.label = "Show contacts",
						.checked = app.show_collision_contacts,
						.on_change = &collision_show_contacts_toggled,
						.style = CHECKBOX_STYLE,
					},
					panel_button("Collision...", &collision_dialog_clicked)
				);
			}
			else
			{
				@node((Label) {
					.text = "Collision check off — turn it on under File › Settings",
					.size = LABEL_SIZE,
					.color = TEXT_DIM,
				}).with_id(PHYSICS_STATUS_ID);
			}

			// ---- the selected chain ----
			@node((Rectangle) { .size = { 0, 1 }, .style = { .color = PANEL_BORDER } });

			@node((Label) {
				.text = physics_selection_line(app, dot),
				.size = FILE_HEADING_SIZE,
				.color = live ? TEXT : TEXT_DIM,
			});

			@node((Label) {
				.text = physics_chain_line(app, chain, id),
				.size = LABEL_SIZE,
				.color = TEXT_DIM,
			});

			@node((Checkbox) {
				.label = "Secondary motion",
				.checked = owned,
				.on_change = &physics_chain_toggled,
				.style = CHECKBOX_STYLE,
			});

			// The two menus: what the chain started from, and where it ends. Greyed
			// rather than gone without a chain, for the reason the sliders are.
			@node(
				(Row) { .gap = PHYSICS_GAP, .cross_align = CENTER },
				(Label) { .text = "Preset", .size = LABEL_SIZE, .color = owned ? TEXT : TEXT_DIM },
				(Select) {
					.options = physics_preset_options[..],
					.selected = (usz)chain.preset,
					.width = 150,
					.style = VIEW_MENU_STYLE,
					.on_change = &physics_preset_chosen,
				}
			).with_id(PHYSICS_PRESET_ID);

			if (owned && app.physics_tip_options.len > 0)
			{
				@node(
					(Row) { .gap = PHYSICS_GAP, .cross_align = CENTER },
					(Label) { .text = "Tip", .size = LABEL_SIZE, .color = TEXT },
					(Select) {
						.options = app.physics_tip_options,
						.selected = tip_row,
						.width = 150,
						.style = VIEW_MENU_STYLE,
						.on_change = &physics_tip_chosen,
					}
				).with_id(PHYSICS_TIP_ID);
			}

			@node((Slider) {
				.label = "Flexibility",
				.value = chain.flexibility,
				.max = 1.0,
				.step = 0.01,
				.decimals = 2,
				.disabled = !owned,
				.on_change = &physics_flexibility_moved,
				.on_commit = &physics_committed,
				.style = PHYSICS_SLIDER_STYLE,
			});

			@node((Slider) {
				.label = "Damping",
				.value = chain.damping,
				.max = 1.0,
				.step = 0.01,
				.decimals = 2,
				.disabled = !owned,
				.on_change = &physics_damping_moved,
				.on_commit = &physics_committed,
				.style = PHYSICS_SLIDER_STYLE,
			});

			@node((Slider) {
				.label = "Gravity",
				.value = chain.gravity,
				.min = PHYSICS_MIN_GRAVITY,
				.max = PHYSICS_MAX_GRAVITY,
				.step = 0.05,
				.decimals = 2,
				.disabled = !owned,
				.on_change = &physics_gravity_moved,
				.on_commit = &physics_committed,
				.style = PHYSICS_SLIDER_STYLE,
			});

			@node((Checkbox) {
				.label = "Collide with character",
				.checked = owned && chain.collide,
				.on_change = &physics_collide_toggled,
				.style = CHECKBOX_STYLE,
			});

			// Where the chain may swing is the Joint card's to edit; said here so
			// a tail that will not fall is not a mystery.
			if (owned)
			{
				@node((Label) {
					.text = app.physics_swing_text,
					.size = LABEL_SIZE,
					.color = TEXT_DIM,
				});
			}

			// ---- what runs, and what it can be turned into ----
			@node((Rectangle) { .size = { 0, 1 }, .style = { .color = PANEL_BORDER } });

			@node((Label) {
				.text = "Animation",
				.size = FILE_HEADING_SIZE,
				.color = TEXT,
			});

			@node(
				(Row) { .gap = PHYSICS_GAP, .cross_align = CENTER },
				(Checkbox) {
					.label = "Simulate",
					.checked = app.sim_enabled,
					.on_change = &physics_sim_toggled,
					.style = CHECKBOX_STYLE,
				},
				panel_button("Bake secondary motion", &physics_bake_clicked)
			);

			@node((Label) {
				.text = physics_state_line(app),
				.size = LABEL_SIZE,
				.color = TEXT_DIM,
			});

			@node((Label) {
				.text = app.physics_summary,
				.size = LABEL_SIZE,
				.color = TEXT_DIM,
			});

			// ---- the old model's one remaining control, out of the way ----
			@node((Rectangle) { .size = { 0, 1 }, .style = { .color = PANEL_BORDER } });

			@node(panel_button(app.physics_advanced ? "Advanced ▾" : "Advanced ▸", &physics_advanced_clicked))
				.with_id(PHYSICS_ADVANCED_ID);

			if (app.physics_advanced)
			{
				@node((Label) {
					.text = "A collider capsule on this bone: an extra body for chains to hit, for a rig with no mesh bound or a KHR runtime.",
					.size = LABEL_SIZE,
					.color = TEXT_DIM,
				});

				@node((Checkbox) {
					.label = "Collider capsule",
					.checked = capsule > 0.0f,
					.on_change = &physics_collider_toggled,
					.style = CHECKBOX_STYLE,
				});

				@node((Slider) {
					.label = "Radius",
					.value = capsule,
					.max = scale * PHYSICS_MAX_RADIUS_SHARE,
					.step = scale * 0.001f,
					.decimals = 3,
					.disabled = capsule <= 0.0f,
					.on_change = &physics_capsule_moved,
					.on_commit = &physics_committed,
					.style = PHYSICS_SLIDER_STYLE,
				});

				@node(panel_button("Clear all secondary motion", &physics_clear_all_clicked));
			}
		};
	};
}

<*
 What the pane says about the simulation: whether anything is being
 simulated, and why not when nothing is.

 The one line that answers "I ticked Secondary motion and nothing moved".
 Physics only runs under a playing clip — there is no other clock for it to
 advance on — and that is not a thing a user can be expected to work out from
 an empty viewport.
*>
fn String physics_state_line(AppState* app) @private
{
	if (!app.sim_enabled) return "simulation off — the clip plays its keys alone";
	if (app.doc.secondary.len() == 0) return "tick Secondary motion on a joint to give it a chain";
	if (!app.animating) return "play a clip to watch it move";
	return "simulating";
}

// The caption over the editor: which bone every control under it is about.
fn String physics_selection_line(AppState* app, Dot* dot) @private
{
	if (!dot) return "no joint selected";
	return dot.name.len > 0 ? dot.name : "unnamed joint";
}

// The line under it: which chain that bone is part of, when it is not the root
// of one — so a click on the middle of a tail says whose sliders these are.
fn String physics_chain_line(AppState* app, SecondaryChain chain, uint selected) @private
{
	if (!chain.present()) return "not part of a chain";
	Dot* tip = app.doc.find(chain.tip);
	String end = tip ? (tip.name.len > 0 ? tip.name : "unnamed") : "(gone)";
	if (chain.root == selected)
	{
		return chain.tip == chain.root ? "roots a chain of one bone" : "roots a chain";
	}
	Dot* root = app.doc.find(chain.root);
	if (!root) return "part of a chain";
	return root.name.len > 0 ? root.name : "unnamed";
}

// ---------------------------------------------------------------------------
// What the controls do
//
// Every one of them reaches the app by type rather than being handed it: a cui
// callback carries only the Ui, which is what keeps these usable from a pane
// that was split, tabbed away and built again.

// The same switch the Animations pane carries: posing is where it acts and
// here is where it is read about, and either box flips the one flag.
fn void physics_prevent_toggled(Ui* ui, bool checked)
{
	AppState* app = ui.inherit(AppState)!!;
	app.set_prevent_intersections(checked);
	app.refresh_ui();
	refresh_animations_view(ui);
	refresh_physics_panel(ui);
}

fn void physics_advanced_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.physics_advanced = !app.physics_advanced;
	refresh_physics_panel(ui);
}

fn void physics_sim_toggled(Ui* ui, bool on)
{
	AppState* app = ui.inherit(AppState)!!;
	app.sim_enabled = on;

	// A sim turned back on has no business replaying whatever the chains were
	// doing when it went off — that history is a question the previous clip asked.
	app.jiggle_reset();
	app.refresh_ui();
	refresh_physics_panel(ui);
}

<*
 Give the selected dot a chain, or take the chain it is part of back.

 Ticking roots a chain at the selected dot with its tip inferred — the run
 below it to the first fork or the end, the same inference
 set_secondary_motion makes — starting from the Tail preset. The rules are
 `AppState.secondary_problem`'s: the root cannot start one, and a run that
 crosses another chain is refused with the sentence said here, where the person
 reading it is looking at the rig rather than at a JSON reply.
*>
fn void physics_chain_toggled(Ui* ui, bool on)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.selected == 0)
	{
		app.@notice("select a joint first");
		refresh_physics_panel(ui);
		return;
	}

	if (!on)
	{
		uint root = app.secondary_root_of(app.selected);
		if (root != 0 && app.clear_secondary_recorded(root)) app.undo_stack.commit();
		app.refresh_ui();
		refresh_physics_panel(ui);
		return;
	}

	RigView? opened = app.open_rig(mem);
	if (catch opened) { refresh_physics_panel(ui); return; }
	RigView view = opened;
	defer view.free(mem);

	SecondaryChain chain = (SecondaryChain){
		.root = app.selected,
		.tip = app.infer_secondary_tip(&view, app.selected),
	}.with_preset(PHYSICS_UI_PRESET);

	String problem = app.secondary_problem(&view, chain);
	if (problem.len > 0)
	{
		app.@notice("%s", problem);
		refresh_physics_panel(ui);
		return;
	}

	if (app.set_secondary_recorded(chain)) app.undo_stack.commit();
	app.refresh_ui();
	refresh_physics_panel(ui);
}

// Start the edited chain over from a preset's values. One undo step, and the
// panel rebuilds so the sliders show where the preset put them.
fn void physics_preset_chosen(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	if (row >= physics_preset_options.len) return;

	SecondaryChain chain = physics_edited_chain(app);
	if (!chain.present())
	{
		app.@notice("tick Secondary motion first — a preset is where a chain's values start");
		refresh_physics_panel(ui);
		return;
	}

	if (app.set_secondary_recorded(chain.with_preset((SecondaryPreset)row))) app.undo_stack.commit();
	app.refresh_ui();
	refresh_physics_panel(ui);
}

// Move the edited chain's tip to the chosen dot below its root, on
// `secondary_problem`'s terms — a tip that would cross another chain is refused.
fn void physics_tip_chosen(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	if (row >= app.physics_tip_ids.len) return;

	SecondaryChain chain = physics_edited_chain(app);
	if (!chain.present()) return;
	chain.tip = app.physics_tip_ids[row];

	RigView? opened = app.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);

	String problem = app.secondary_problem(&view, chain);
	if (problem.len > 0)
	{
		app.@notice("%s", problem);
		refresh_physics_panel(ui);
		return;
	}

	if (app.set_secondary_recorded(chain)) app.undo_stack.commit();
	app.refresh_ui();
	refresh_physics_panel(ui);
}

// Whether the edited chain is pushed out of the character. Structural, so the
// panel rebuilds.
fn void physics_collide_toggled(Ui* ui, bool on)
{
	AppState* app = ui.inherit(AppState)!!;
	SecondaryChain chain = physics_edited_chain(app);
	if (!chain.present())
	{
		app.@notice("tick Secondary motion first");
		refresh_physics_panel(ui);
		return;
	}

	chain.collide = on;
	if (app.set_secondary_recorded(chain)) app.undo_stack.commit();
	app.refresh_ui();
	refresh_physics_panel(ui);
}

<*
 Put a capsule on the selected bone, or take it off.

 The radius it arrives with is set_secondary_motion's own default — a quarter
 of that bone's rest length — so a capsule ticked on here is the same capsule an
 agent would have made, and it is a sleeve around the limb rather than a number
 picked out of the air.
*>
fn void physics_collider_toggled(Ui* ui, bool on)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.selected == 0)
	{
		app.@notice("select a joint first");
		refresh_physics_panel(ui);
		return;
	}

	float radius = 0.0f;
	if (on)
	{
		radius = physics_default_capsule(app, app.selected);
		if (radius <= 0.0f)
		{
			app.@notice("this joint's bone has no length to measure a capsule from");
			refresh_physics_panel(ui);
			return;
		}
	}

	if (app.set_collider_recorded(app.selected, radius)) app.undo_stack.commit();
	app.refresh_ui();
	refresh_physics_panel(ui);
}

// Everything off every bone, as one undo step: a rig whose physics is being
// started over is one gesture, not one per tail.
fn void physics_clear_all_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	usz cleared = 0;
	// Backwards, because clearing an entry removes it from the list being walked.
	for (sz i = app.doc.secondary.len() - 1; i >= 0; i--)
	{
		if (app.clear_secondary_recorded(app.doc.secondary.get(i).root)) cleared++;
	}
	for (sz i = app.doc.colliders.len() - 1; i >= 0; i--)
	{
		if (app.set_collider_recorded(app.doc.colliders.get(i).dot_id, 0.0f)) cleared++;
	}

	if (cleared == 0)
	{
		app.@notice("nothing on this rig has secondary motion");
		return;
	}

	app.undo_stack.commit();
	app.@notice("cleared %d", cleared);
	app.refresh_ui();
	refresh_physics_panel(ui);
}

<*
 Simulate the playing clip and write what the chains did into a clip of its own.

 The panel's half of `bake_physics`: physics exists only while the player is
 running, so a tail that swings on screen swings in no export until this has been
 pressed.

 The clip that is playing rather than one chosen here, because that is the one
 the values above were tuned against — and tuning against a clip is the whole
 way the values got where they are. The sim is built the way the viewport's is
 — the skin as its surface, the radii measured, the limits read — so the bake
 collides with what was watched.
*>
fn void physics_bake_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	if (!app.animating)
	{
		app.@notice("play the clip you want baked first");
		return;
	}

	AnimRef ref = app.current_ref;
	AnimTemplate* source = app.clip(ref);
	if (!source)
	{
		app.@notice("the playing clip is no longer in the library");
		return;
	}
	String source_name = source.name;

	RigView? opened = app.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);

	JiggleChainSpec[] chains;
	JiggleColliderSpec[] colliders;
	jiggle_specs_from_document(mem, &app.doc, &view.skeleton, view.dot_ids, &chains, &colliders);
	defer free_jiggle_specs(mem, chains, colliders);

	if (chains.len == 0)
	{
		app.@notice("nothing on this rig has secondary motion — tick it on a chain first");
		return;
	}

	JiggleSim? assembled = app.build_dressed_sim(&view, chains, colliders);
	if (catch assembled)
	{
		app.@notice("those chains do not describe a run that can be simulated");
		return;
	}
	JiggleSim sim = assembled;
	defer sim.free(mem);
	defer app.release_jiggle_surface();

	AnimTemplate? made = bake_physics_clip(
		mem, *source, &view.skeleton, view.names, &sim, "", (float)BAKE_DEFAULT_HZ, BAKE_DEFAULT_SETTLE,
		&app.doc, view.dot_ids);
	if (catch made)
	{
		app.@notice("\"%s\" has no keyframes to simulate over", source_name);
		return;
	}

	bool replaced;
	AnimRef landed = app.put_authored_clip(made, &replaced);
	app.undo_stack.commit();

	AnimTemplate* baked = app.clip(landed);
	app.@notice("%s \"%s\" — %d keyframes",
		replaced ? "replaced" : "baked", baked ? baked.name : source_name,
		baked ? baked.keyframes.len : 0);
	app.refresh_ui();
	refresh_physics_panel(ui);
}

// ---------------------------------------------------------------------------
// The sliders
//
// Each takes the value it was dragged to, puts it in its own field and writes
// the whole chain back — `set_secondary` overwrites rather than merges, so a
// setter that wrote one number would clear the rest.

// The chain the panel's sliders are about: the one the selected dot is part
// of, read through the same cache the snapshot uses so a drag costs no rig
// build per pixel.
fn SecondaryChain physics_edited_chain(AppState* app) @private
{
	return app.doc.secondary_of(app.secondary_root_of(app.selected));
}

fn void physics_flexibility_moved(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	SecondaryChain chain = physics_edited_chain(app);
	chain.flexibility = value;
	physics_slide(app, chain);
}

fn void physics_damping_moved(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	SecondaryChain chain = physics_edited_chain(app);
	chain.damping = value;
	physics_slide(app, chain);
}

fn void physics_gravity_moved(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	SecondaryChain chain = physics_edited_chain(app);
	chain.gravity = value;
	physics_slide(app, chain);
}

fn void physics_capsule_moved(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.selected == 0) return;

	app.set_collider_recorded(app.selected, value);
	app.refresh_ui();
}

// Write and show, without closing the undo group: the release does that, so a
// drag is one step however many pixels it crossed.
fn void physics_slide(AppState* app, SecondaryChain chain) @private
{
	if (!chain.present()) return;

	app.set_secondary_recorded(chain);

	// The overlay and the HUD, not the panel: a rebuild here would release the
	// slider the pointer is holding. The sim itself needs no telling — the setter
	// marked it stale, and the next frame of playback builds the one this document
	// now describes.
	app.refresh_ui();
}

// The end of a drag: one entry in the ledger, and the lines under the sliders
// catch up with what they were dragged to.
fn void physics_committed(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	app.undo_stack.commit();
	refresh_physics_panel(ui);
}

<*
 How fat a capsule on this bone starts out: a quarter of its own rest length,
 which reads as a limb-shaped sleeve on every rig proportioned like a figure.

 The same share set_secondary_motion uses, and derived from the rig rather than
 picked in model units for the same reason — it is the same sleeve on a mouse
 and on an elephant.
*>
fn float physics_default_capsule(AppState* app, uint id) @private
{
	RigView? opened = app.open_rig(mem);
	if (catch opened) return 0.0f;
	RigView view = opened;
	defer view.free(mem);

	sz joint = view.joint_of(id);
	if (joint < 0) return 0.0f;

	Vec3[] tails = view.skeleton.tails(mem);
	defer alloc::free(mem, tails);

	float bone = (tails[joint] - view.skeleton.joints[joint]).length();
	return bone * PHYSICS_COLLIDER_SHARE;
}
