<*
 Asking before a body plan replaces the rig that is already there.

 Applying a plan replaces the document's dots — see `AppState.apply_preset` for
 why two rigs in one document is not a state worth offering — so the paths a
 person clicks come through here first, and the ones a script drives do not.
 `--preset` on the command line said what it wanted; a click on **Use this rig**
 with seventeen dots already placed may not have.

 **The question is asked once, not every time.** An empty document has nothing
 to lose, so `request_pack_rig` applies straight away and no panel appears. That
 is the common first run, and a confirmation nobody could answer differently is
 a click taken from them.

 Undo covers the answer either way: the clearing and the placing are one entry,
 so a wrong Replace costs a Ctrl+Z. The dialog is here because a rig can be an
 afternoon's work and a modal is cheaper than trusting the user still has the
 history.

 The panel itself is `cui::ConfirmDialog`, which owns the sentence it shows —
 the question is formatted at the moment it is asked and copied in, so nothing
 about it has to be parked on `AppState` to survive the click.
*>
module crig;

import cui;
import cui::widgets;
import std::core::string;

const String CONFIRM_DIALOG_ID = "confirm-dialog";

<*
 Apply a pack's body plan, asking first when there is a rig to lose.

 The one door every interactive path to a body plan goes through — the library's
 **Use this rig** today, and anything else that grows one later. Applies nothing
 itself unless the document is empty; otherwise the dialog's own button does.

 @param pack : `Index into the library. Out of range asks nothing and applies nothing.`
*>
fn void request_pack_rig(Ui* ui, int pack)
{
	AppState* app = ui.inherit(AppState)!!;
	if (pack < 0 || pack >= app.packs.len()) return;

	if (app.doc.dots.len() == 0)
	{
		fit_pack_offering_turn(ui, (usz)pack);
		app.refresh_ui();
		return;
	}

	AnimPack* chosen = app.pack((usz)pack);
	if (!chosen) return;

	Element*? panel = ui.find_id(CONFIRM_DIALOG_ID);
	if (catch panel)
	{
		// No panel in this tree to ask through. Applying anyway would be the one
		// outcome the asking exists to prevent, so the plan is left alone.
		app.@notice("nowhere to confirm replacing the rig");
		return;
	}

	// Which pack was asked about outlives the click: `on_confirm` is a bare
	// function pointer, so the answer has to find its way back to a pack index
	// through the app rather than through the callback.
	app.pending_rig_pack = pack;

	// Temporary on purpose — `ConfirmDialog.ask` copies it, which is the whole
	// reason the sentence does not need a home on AppState.
	panel.widget_as(ConfirmDialog).ask(
		panel,
		string::tformat("%s will replace the rig you have now — %d joints and %d bones.",
			chosen.name, app.doc.dots.len(), app.doc.edges.len()),
		&rig_replace_confirmed,
		&rig_replace_declined);
}

<*
 Settle the standing question, whichever way.

 One function for both answers rather than one per button, so "what does
 declining leave behind" is answered in the same place as "what does accepting
 do" — the two are a pair, and the dangerous half of a confirmation is the half
 that quietly does something on the way out.

 The request is cleared before the plan is applied rather than after, so a pack
 that refuses to fit cannot leave a question standing that has been answered.
 Answering when nothing was asked does nothing at all.

 @param replace : `True applies the parked plan; false leaves the rig alone.`
*>
fn void answer_rig_dialog(Ui* ui, bool replace)
{
	AppState* app = ui.inherit(AppState)!!;
	int pack = app.pending_rig_pack;
	app.pending_rig_pack = -1;

	if (!replace) return;
	if (pack < 0 || pack >= app.packs.len()) return;

	fit_pack_offering_turn(ui, (usz)pack);
	app.refresh_ui();
}

fn void rig_replace_confirmed(Ui* ui) @private => answer_rig_dialog(ui, true);

// Cancel, the close button, ESC — `ConfirmDialog` reports all of them here, so
// there is no way out that leaves the request standing.
fn void rig_replace_declined(Ui* ui) @private => answer_rig_dialog(ui, false);

<*
 Fits a pack's body plan, and when the fit came out facing -Z offers a one-click
 Turn around (see `open_turn_offer`). The interactive door only: an MCP or
 scripted fit reports the facing in its notice and is not interrupted.
*>
fn void fit_pack_offering_turn(Ui* ui, usz pack)
{
	AppState* app = ui.inherit(AppState)!!;
	app.fit_reversed = false;
	if (app.apply_pack_rig(pack) && app.fit_reversed) open_turn_offer(ui);
}
