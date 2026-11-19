<*
 The Animations dock showing a cutscene, while its preview is on: the chooser and
 + New, the transport, the Pieces bin beside the sheet, and CutSide on the right.
 The frame and ids are the clip dock's. Picking a clip in the chooser gives the
 dock back to the character.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const String CUT_START_ID = "cut-start";
const String CUT_PLAY_ID = "cut-play";
const String CUT_END_ID = "cut-end";
const String CUT_TIME_ID = "cut-time";
const String CUT_PIECE_BIN_ID = "cut-piece-bin";

<* What decides the cutscene dock's shape; a change rebuilds it. The bin and the sheet follow on their own, the picked strip is CutSide's. *>
struct CutPanelShape
{
	uint revision;
	usz cutscenes;
	usz active;
	bool preview;
	bool playing;
	bool one_off;
	// The chooser lists the focus's clips.
	uint focus;
	usz bound;
}

fn CutPanelShape cut_panel_shape(AppState* app) @private
{
	return {
		.revision = app.cut_revision,
		.cutscenes = (usz)app.cutscenes.len(),
		.active = app.cut_active,
		.preview = app.cut_preview,
		.playing = app.cut_playing,
		.one_off = app.one_off_open(),
		.focus = app.id,
		.bound = (usz)app.doc.animations.len(),
	};
}

<*
 Rebuild when the shape changes, not as the playhead moves; never under a held press or a field being typed in.

 @param [&inout] elem
 @param [&in] app
*>
fn void AnimPanel.update_cut_dock(&self, Element* elem, AppState* app)
{
	CutPanelShape now = cut_panel_shape(app);
	if (self.cut_mode && !fields_differ(now, self.cut_shown)) return;
	if (layer_sheet_busy(elem.ui)) return;
	if (cut_rebuild_waits(elem, self.cut_mode && now.revision == self.cut_shown.revision)) return;
	elem.request_build();
}

<*
 The dock's tree with the cutscene on show, in the clip dock's frame.

 @param [&inout] elem
 @param [&in] app
 @return "The dock"
*>
fn Element* AnimPanel.build_cut_dock(&self, Element* elem, AppState* app)
{
	self.cut_shown = cut_panel_shape(app);
	Element* dock = @subtree(elem.ui)
	{
		@tree((AnimDock) { })
		{
			Element* clip_side = @tree((Scroll) { })
			{
				@tree((Padding) { .insets = widgets::insets_all(ANIM_PAD) })
				{
					@tree((AnimClipManager) { .gap = ANIM_GAP })
					{
						@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = ANIM_GAP, .cross_align = CENTER })
						{
							@node((AnimChooser) { });
							@tree(widgets::tip("New — an animation of this character, or a cutscene of the scene"))
							{
								@node(panel_button("+ New", &anim_new_menu_clicked)).with_id(ANIM_NEW_ID);
							};
						};
						@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = ANIM_GAP, .cross_align = CENTER })
						{
							@tree(widgets::tip("Start (Home) — jump to the cutscene's first frame"))
							{
								@node(panel_button("|<", &cut_start_clicked)).with_id(CUT_START_ID);
							};
							@tree(widgets::tip("Play / pause (Space) — the cutscene from the playhead"))
							{
								@node(accent_button(app.cut_playing ? "❚❚" : "▶", &cut_play_clicked)).with_id(CUT_PLAY_ID);
							};
							@tree(widgets::tip("End (End) — jump to the cutscene's last frame"))
							{
								@node(panel_button(">|", &cut_end_clicked)).with_id(CUT_END_ID);
							};
							@node((CutTimeLabel) { }).with_id(CUT_TIME_ID);
						};
						Element* deck = @tree((AnimLayerDeck) { })
						{
							// The bin's action cells each say what they do.
							@tree(widgets::tip_probe(&piece_bin_tip))
							{
								@node((PieceBin) { .for_cut = true }).with_id(CUT_PIECE_BIN_ID);
							};
							@node((CutsceneTimeline) { }).with_id(CUT_TIMELINE_ID);
						};
						deck.with_id(ANIM_SHEET_SLOT_ID);
					};
				};
			};
			clip_side.with_id(ANIM_CLIP_SIDE_ID);
			@node((AnimDockDivider) { }).with_id(ANIM_DIVIDER_ID);
			// CutSide scrolls and pads on its own.
			Element* side = @tree((Padding) { .insets = widgets::insets_all(0) })
			{
				@node((CutSide) { }).with_id(CUT_SIDE_ID);
			};
			side.with_id(ANIM_LAYERS_SIDE_ID);
		};
	};
	dock.with_id(ANIM_DOCK_ID);
	return dock;
}

<* With the cutscene on show, Delete or Backspace deletes the picked strip wherever in the dock the last click was; Enter edits its one-off. *>
fn bool AnimPanel.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down || !self.cut_mode || !elem.inherit(AppState)!!.cutscene_in_dock()) return false;
	if (event.key == Key.RETURN || event.key == Key.KP_RETURN) return edit_picked_one_off(elem.ui);
	if (event.key != Key.DELETE && event.key != Key.BACKSPACE) return false;
	return delete_picked_cut_strip(elem.ui);
}

<*
 The transport's keys with the cutscene on show: Space plays or pauses, Home and End jump to
 its ends, the arrows and , . step one frame of its rate.
*>
fn bool cut_transport_key(Ui* ui, Key key)
{
	AppState* app = ui.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	if (!cutscene) return false;
	switch (key)
	{
		case Key.SPACE: cut_play_clicked(ui);
		case Key.HOME: cut_seek(ui, 0.0f);
		case Key.END: cut_seek(ui, cutscene.duration);
		case Key.COMMA:
		case Key.PERIOD:
		case Key.LEFT_ARROW:
		case Key.RIGHT_ARROW:
			cut_seek(ui, app.cut_time + (float)transport_step(key) * cut_frame(cutscene));
		default: return false;
	}
	return true;
}

// One frame of the cutscene's rate, in seconds.
fn float cut_frame(Cutscene* cutscene) @private => cutscene.fps > 0.0f ? 1.0f / cutscene.fps : 0.01f;

<* A held frame-step key with the cutscene on show: one frame of its rate per frame due, as for a clip. *>
fn bool TransportRepeat.advance_cut(&self, Ui* ui, AppState* app, float dt)
{
	Cutscene* cutscene = app.cutscene();
	if (!ui.input.key_down(self.key) || !cutscene)
	{
		self.key = Key.EMPTY;
		return false;
	}
	self.wait -= dt;
	if (self.wait > 0.0f) return true;
	float frame = cut_frame(cutscene);
	int steps = (int)(-self.wait / frame) + 1;
	self.wait += (float)steps * frame;
	float to = math::clamp(app.cut_time + (float)(steps * transport_step(self.key)) * frame, 0.0f, cutscene.duration);
	if (to != app.cut_time) cut_seek(ui, to);
	return true;
}

// A jump pauses the cutscene, as a clip's does.
fn void cut_seek(Ui* ui, float t) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.cutscene()) return;
	(void)app.play_cutscene(false);
	app.show_cutscene_at(t);
	app.refresh_ui();
}

fn void cut_start_clicked(Ui* ui) @private => cut_seek(ui, 0.0f);

fn void cut_end_clicked(Ui* ui) @private
{
	Cutscene* cutscene = ui.inherit(AppState)!!.cutscene();
	if (cutscene) cut_seek(ui, cutscene.duration);
}

fn void cut_play_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.play_cutscene(!app.cut_playing)) app.@notice("add a cutscene to play");
	app.refresh_ui();
}

<* The playhead's time over the cutscene's length, kept current while it plays. *>
struct CutTimeLabel (Widget)
{
	char[48] said; // what `describe` answers, kept while it is read
	float painted; // the time last drawn, so a move from anywhere repaints it
}

fn Vec2 CutTimeLabel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ 120.0f, CARD_ICON_VIEW });
}

fn void CutTimeLabel.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	if (!cutscene) return;
	self.painted = app.cut_time;
	String text = string::tformat("%.2f / %.2f s", app.cut_time, cutscene.duration);
	painter.text({ 6.0f, (elem.size.y - ANIM_TEXT_SIZE) * 0.5f }, text, { .size = ANIM_TEXT_SIZE, .color = TEXT });
}

fn void CutTimeLabel.update(&self, Element* elem, float dt) @dynamic
{
	if (elem.inherit(AppState)!!.cut_time != self.painted) elem.request_paint();
}

fn void CutTimeLabel.describe(&self, Element* elem, Description* out) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	if (cutscene) out.text = string::bformat(&self.said, "%.2f / %.2f s", app.cut_time, cutscene.duration);
}
