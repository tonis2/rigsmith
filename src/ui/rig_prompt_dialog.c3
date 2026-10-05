<*
 Saying that a mesh arrived with nothing to pose it by.

 A `.glb` with no skin lands in `adopt_source_rig`'s third tier: an empty
 document over a model that has no skeleton to import. That is an ordinary way
 for a game developer's own mesh to arrive — they modelled it, exported it, and
 it has never been rigged — and until this panel existed crig answered it with
 nothing at all. No notice, no hint, and the only route to a body plan was a cell
 in the Assets pane, which is not a pane a first run necessarily has open and not
 a cell that reads as "rig this".

 Worse, one thing *did* happen automatically and looked arbitrary: playing an
 animation on an empty document fits that pack's rig first (`AppState.play_clip`).
 So the user's experience was "it did something confusing" — nothing when they
 opened the mesh, and a skeleton they did not ask for when they started a clip.
 This panel is the first half of the answer; the notice `play_clip` now emits is
 the second.

 That surprise is now one step further off: the Assets grid no longer plays what
 it lists, so reaching `play_clip` at all means binding a clip and pressing Play
 in the Animations pane — two deliberate acts rather than one stray click.

 **It offers the list rather than pointing at it.** "Apply a skin template from
 the asset library" is instructions; a row per plan with a button under it is the
 thing itself. The rows come from the packs that are body plans in their own
 right — `AnimPack.is_body_plan`, which `scan_libraries` has already loaded in
 full, so nothing is read off disk to fill this.

 **Rows are named by pack, not by plan.** A library easily holds three files
 declaring `biped` (the shipped `humanoid.glb`, a saved `biped.glb`, a
 downloaded `mixamo.glb`), so a list keyed on the plan tag would be three rows
 all reading "Biped" — worse than the silence it replaces. The tag rides in the
 trailing column, where it groups without being the only thing said.

 Not modal, and closing on an outside click. It is an offer, not a question: a
 user who would rather place dots by hand should be able to start doing it by
 clicking the model, and one who wants the panel back has Rig > Apply body plan.
*>
module crig;

import cui;
import cui::widgets;


import std::math;
import std::math::vector;

const String RIG_PROMPT_DIALOG_ID = "rig-prompt-dialog";
const String RIG_PROMPT_PANEL_ID = "rig-prompt-panel";
const String RIG_PROMPT_LIST_ID = "rig-prompt-list";

const float RIG_PROMPT_W = 460.0;
const float RIG_PROMPT_GAP = 10.0;

// Six rows, for `SETTINGS_LIST_H`'s reason: a fixed box, so the panel is the
// same size whatever the library holds and does not jump under the pointer as
// folders are added. Six because the shipped library already offers five body
// plans, and a first run that has to scroll to see the last one is a first run
// that does not know it is there.
const float RIG_PROMPT_LIST_H = 6 * TREE_STYLE.row_height;

const String RIG_PROMPT_LEAD =
	"This mesh has no skeleton, so there is nothing to pose or animate yet.";

const String RIG_PROMPT_HELP =
	"Pick a body plan to fit one to it, or close this and place the joints yourself.";

// What the list says when the library holds no body plan at all. Distinct from
// "no libraries configured" only in that the fix is different, and naming the fix
// is the whole job of an empty state.
const String RIG_PROMPT_NO_PLANS =
	"No body plans in your libraries — add a folder in File > Settings";

<*
 Rebuild the body-plan rows from the loaded packs.

 Labels are borrowed from the packs, which outlive the panel but not a rescan —
 so anything that reloads the library rebuilds these before the tree is drawn
 again, the rule `refresh_library_rows` follows for the same reason.

 `plan_row_packs` is the second array that turns "row 2 was clicked" back into a
 pack index, because `TreeRow` is cui's and knows nothing about packs.
*>
fn void AppState.refresh_plan_rows(&self)
{
	self.free_plan_rows();

	usz count = 0;
	foreach (&pack : self.packs)
	{
		if (pack.is_body_plan()) count++;
	}
	if (count == 0) return;

	self.plan_rows = alloc::new_array(mem, TreeRow, (sz)count);
	self.plan_row_packs = alloc::new_array(mem, int, (sz)count);

	usz row = 0;
	foreach (usz i, &pack : self.packs)
	{
		if (!pack.is_body_plan()) continue;
		self.plan_rows[row] = {
			.label = pack.name.len > 0 ? pack.name : base_name(pack.path),
			// The plan tag alongside rather than as the label: it is what groups
			// three biped packs, and it is not what tells them apart.
			.trailing = pack.plan,
			.depth = 0,
		};
		self.plan_row_packs[row] = (int)i;
		row++;
	}
}

fn void AppState.free_plan_rows(&self)
{
	if (self.plan_rows.len > 0) alloc::free(mem, self.plan_rows);
	if (self.plan_row_packs.len > 0) alloc::free(mem, self.plan_row_packs);
	self.plan_rows = {};
	self.plan_row_packs = {};
}

<*
 Open the panel.

 Raised from `AppRoot.update` when `wants_rig_prompt` is standing, and from
 Rig > Apply body plan when the user asks for it directly. The two are the same
 panel on purpose: whatever taught them the verb, it is the same verb.
*>
fn void open_rig_prompt(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.rig_prompt_while_bare = app.doc.dots.len() == 0;
	set_dialog_open(ui, RIG_PROMPT_DIALOG_ID, true);
}

fn void close_rig_prompt(Ui* ui)
{
	set_dialog_open(ui, RIG_PROMPT_DIALOG_ID, false);
}

fn Element* build_rig_prompt_body(Ui* ui)
{
	return @subtree(ui)
	{
		@node((RigPromptPanel) { }).with_id(RIG_PROMPT_PANEL_ID);
	};
}

// One widget rather than a bare subtree, for `SettingsPanel`'s reason: something
// has to be askable for a rebuild when the library changes under it.
struct RigPromptPanel (Widget)
{
	char no_state;
}

fn Element* RigPromptPanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	app.refresh_plan_rows();

	return @subtree(elem.ui)
	{
		@tree((Column) { .size = { RIG_PROMPT_W, 0 }, .gap = RIG_PROMPT_GAP })
		{
			// Both colours are explicit: `Label`'s zero colour is fully transparent,
			// so an unstyled one lays out at the right size and paints nothing —
			// which reads as a gap in the panel rather than as a missing line.
			@node((Label) { .text = RIG_PROMPT_LEAD, .size = FILE_HEADING_SIZE, .color = TEXT });
			@node((Label) { .text = RIG_PROMPT_HELP, .size = FILE_HEADING_SIZE, .color = TEXT_DIM });

			@tree((Scroll) { .size = { RIG_PROMPT_W, RIG_PROMPT_LIST_H } })
			{
				@node((EmptyStateTree) { .rows_of = &rig_prompt_plan_rows, .empty = RIG_PROMPT_NO_PLANS,
					.empty_color = TEXT_DIM, .style = TREE_STYLE, .tree_id = RIG_PROMPT_LIST_ID });
			};

			@node(
				(Row) { .gap = RIG_PROMPT_GAP },
				accent_button("Fit this plan", &rig_prompt_apply),
				panel_button("I'll place the joints", &rig_prompt_dismiss)
			);
		};
	};
}

// The body plans for the prompt's list. The first preselected, unlike the
// settings list: there is a sensible default here and the button under it is
// the point of the panel, where "Remove selected" is a destructive act that
// should have to be aimed.
fn TreeRow[] rig_prompt_plan_rows(Element* elem, usz* selected) @private
{
	*selected = 0;
	return elem.inherit(AppState)!!.plan_rows;
}

// ---------------------------------------------------------------------------
// What the buttons do

<*
 Fit the selected plan to the mesh.

 Through `request_pack_rig`, which is the one door every interactive path to a
 body plan goes through — so this asks before replacing a rig exactly as the
 Assets pane does. On the empty document this panel exists for it applies
 straight through, which is the case it was written for.
*>
fn void rig_prompt_apply(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	Tree*? list = ui.get_widget_id(RIG_PROMPT_LIST_ID, Tree);
	if (catch list) return;
	if (list.selected >= app.plan_row_packs.len)
	{
		app.@notice("pick a body plan to fit");
		return;
	}

	int pack = app.plan_row_packs[(usz)list.selected];
	close_rig_prompt(ui);
	request_pack_rig(ui, pack);
}

<*
 Close, and take the standing request with it.

 The flag is lowered when the panel opens rather than here, so this is only the
 close — but it is a separate button from the title bar's X on purpose: a panel
 whose only way out is the corner reads as something that went wrong.
*>
fn void rig_prompt_dismiss(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	close_rig_prompt(ui);
	app.@notice("place joints with the pointer, or Rig > Apply body plan to fit one");
}

// ---------------------------------------------------------------------------
// After a fit that came out facing -Z

const String TURN_OFFER_DIALOG_ID = "turn-offer-dialog";
const String TURN_OFFER_APPLY_ID = "turn-offer-apply";

const String TURN_OFFER_TEXT = "The body plan was fitted facing -Z, away from the front view.";
const String TURN_OFFER_HELP = "The facing is measured and can be wrong. Turning is one undo step.";

fn void open_turn_offer(Ui* ui)
{
	set_dialog_open(ui, TURN_OFFER_DIALOG_ID, true);
}

fn Element* build_turn_offer_body(Ui* ui)
{
	return @subtree(ui)
	{
		@tree((Column) { .size = { RIG_PROMPT_W, 0 }, .gap = RIG_PROMPT_GAP })
		{
			@node((Label) { .text = TURN_OFFER_TEXT, .size = FILE_HEADING_SIZE, .color = TEXT });
			@node((Label) { .text = TURN_OFFER_HELP, .size = FILE_HEADING_SIZE, .color = TEXT_DIM });
			@tree((Row) { .gap = RIG_PROMPT_GAP })
			{
				@node(accent_button("Turn around", &turn_offer_apply)).with_id(TURN_OFFER_APPLY_ID);
				@node(panel_button("Keep it", &turn_offer_dismiss));
			};
		};
	};
}

<*
 Turns the whole skeleton 180° about Y, as one undo step — Rig > Rotate
 skeleton's Y 180°, without the dialog.
*>
fn void turn_offer_apply(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, TURN_OFFER_DIALOG_ID, false);
	usz moved = app.rotate_skeleton(1, (float)math::PI);
	if (moved == 0)
	{
		app.@notice("the skeleton could not be turned");
		return;
	}
	app.refresh_pose_display();
	app.@notice("turned the skeleton around · %d joints · Ctrl+Z turns it back", moved);
	app.refresh_ui();
}

fn void turn_offer_dismiss(Ui* ui)
{
	set_dialog_open(ui, TURN_OFFER_DIALOG_ID, false);
}
