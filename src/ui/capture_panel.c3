<*
 The Capture pane: an animation of the character out of a video of it. The work
 is `app/capture.c3`; this is the pane it is driven from, three steps top to
 bottom:

 1. Joint finder: train one on renders of this character (about half an hour),
    or use one trained before.
 2. Reference picture: the character from the front and its right side in one
    picture, from a pose picked here. A video model (MiniMax, Seedance)
    animates it; the prompt to give it is a click away.
 3. Animate from video: the video the model made, read into a clip on the
    character.

 While a step runs the pane shows its progress and a Stop; one pipeline job
 runs at a time, shared with the Generate pane.
*>
module crig;
import cui;
import cui::widgets;
import std::io;
import std::math;
import std::math::vector;
import std::io::file;
import std::os::process;
import std::core::string;

const String CAPTURE_PANEL_ID = "capture-panel";
const String CAPTURE_POSES_ID = "capture-poses";
const String CAPTURE_TIME_ID = "capture-time";
const String CAPTURE_ACTION_ID = "capture-action";
const String CAPTURE_VIDEO_ID = "capture-video";
const String CAPTURE_NAME_ID = "capture-name";
const String CAPTURE_POSE_ID = "capture-pose";
// The pose chooser's first row: the rig's rest pose rather than a clip.
const String CAPTURE_REST = "<rest>";

fn Element* build_capture_view(Ui* ui)
{
	return @subtree(ui)
	{
		@tree((Scroll) { })
		{
			@tree((Padding) { .insets = widgets::insets_all(ANIM_PAD) })
			{
				@node((CapturePanel) { }).with_id(CAPTURE_PANEL_ID);
			};
		};
	};
}

fn void refresh_capture_view(Ui* ui)
{
	ui.@each_id(CAPTURE_PANEL_ID; panel)
	{
		panel.request_build();
	};
}

fn void open_capture_panel(Ui* ui) => show_pane_view(ui, CAPTURE_VIEW, SplitAxis.HORIZONTAL, 2.0f / 3.0f);

<*
 What decides the pane's shape: rebuilt when a control comes or goes, or a
 step ends (its statuses change), never for a number.
*>
struct CaptureSnapshot
{
	bool has_file;
	bool configured;
	bool skeleton;
	bool running;
	CaptureStage stage;
	bool failed;
	uint finished;
	usz clips;
}

fn CaptureSnapshot capture_snapshot(AppState* app) @private
{
	usz clips;
	foreach (pack : app.packs) clips += pack.clips.len;
	return {
		.has_file = app.source_path.len > 0,
		.configured = app.config.motion_generator.creature_model.len > 0,
		.skeleton = app.doc.dots.len() > 0 && app.has_mesh(),
		.running = app.capture_job.running,
		.stage = app.capture_job.stage,
		.failed = app.capture_job.failed && !app.capture_job.running,
		.finished = app.capture_job.finished,
		.clips = clips,
	};
}

fn bool CaptureSnapshot.differs(self, CaptureSnapshot other)
{
	return self.has_file != other.has_file || self.configured != other.configured || self.skeleton != other.skeleton
		|| self.running != other.running || self.stage != other.stage || self.failed != other.failed
		|| self.finished != other.finished || self.clips != other.clips;
}

struct CapturePanel (Widget)
{
	CaptureSnapshot shown;
	// Statuses the labels point at between builds, so held here.
	char[160] finder_line;
	char[300] reference_line;
}

fn Vec2 CapturePanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	float width = constraints.max.x;
	Vec2 inner = elem.layout_child(0, cui::loose({ width, constraints.max.y }));
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ width, inner.y });
}

fn void CapturePanel.update(&self, Element* elem, float dt) @dynamic
{
	CaptureSnapshot now = capture_snapshot(elem.inherit(AppState)!!);
	if (!now.differs(self.shown)) return;
	self.shown = now;
	elem.request_build();
}

fn Element* CapturePanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.shown = capture_snapshot(app);
	CaptureDraft* draft = &app.capture_draft;
	if (draft.poses.len == 0) draft.poses = string::format(mem, "%d", CAPTURE_DEFAULT_POSES);
	if (draft.pose_time.len == 0) draft.pose_time = "0".copy(mem);
	CaptureJob* job = &app.capture_job;

	String finder = app.capture_finder();
	String summary = finder_summary(finder);
	String finder_text = finder.len == 0 ? "No joint finder yet."
		: (String)io::bprintf(self.finder_line[..], "%s%s%s", base_name(finder), summary.len > 0 ? " · " : "", summary) ?? "A joint finder is set.";
	String studio = app.capture_path("studio");
	bool has_reference = app.source_path.len > 0 && file::exists(string::tformat("%s/reference.png", studio));
	String reference_text = has_reference ? (String)io::bprintf(self.reference_line[..], "%s/reference.png", studio) ?? "reference.png"
		: "No reference picture yet.";

	Element* body = @subtree(elem.ui)
	{
		@tree((Column) { .gap = ANIM_GAP })
		{
			@node((Label) { .text = "Video capture", .size = 16, .color = TEXT });
			@node((GenerateNote) { .text = "Animate this character from a video of it: train a joint finder on it once, make the reference picture, have a video model (MiniMax, Seedance) animate the picture, then read the video here.",
				.size = 12, .color = TEXT_DIM });
			if (!self.shown.has_file)
			{
				@node((GenerateNote) { .text = "Open or save the model as a .glb first: the capture's files go in a folder beside it.",
					.size = ANIM_TEXT_SIZE, .color = ACCENT });
			}
			else if (!self.shown.skeleton)
			{
				@node((GenerateNote) { .text = "This model has no skinned skeleton yet. Rig it first; the clip is put on the rig.",
					.size = ANIM_TEXT_SIZE, .color = ACCENT });
			}
			else
			{
				if (!self.shown.configured)
				{
					@node((GenerateNote) { .text = "Training and reading need the DINOv3 backbone: in File › Settings › AI, choose SAM 3D Body's model.ckpt under Video capture.",
						.size = ANIM_TEXT_SIZE, .color = ACCENT });
					@node(accent_button("Open AI settings", &open_ai_settings)).with_id("capture-open-settings");
				}

				// 1. The joint finder.
				@node((Label) { .text = "1 · Joint finder", .size = 14, .color = TEXT });
				@node((GenerateNote) { .text = finder_text, .size = ANIM_TEXT_SIZE, .color = finder.len > 0 ? TEXT : TEXT_DIM });
				@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
				{
					@node(accent_button(finder.len > 0 ? "Train again" : "Train finder", &capture_train_clicked)).with_id("capture-train");
					@node(panel_button("Use existing…", &capture_use_finder_clicked)).with_id("capture-use-finder");
					@node((Label) { .text = "Poses", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 60, .style = TEXT_FIELD_STYLE, .on_change = &capture_poses_changed }).with_id(CAPTURE_POSES_ID);
				};
				@node((GenerateNote) { .text = "Training draws the character in that many poses from the front and both sides, then teaches the finder where its joints are: about half an hour. A stopped run carries on where it stopped.",
					.size = 12, .color = TEXT_DIM });

				// 2. The reference picture.
				@node((Label) { .text = "2 · Reference picture", .size = 14, .color = TEXT });
				@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
				{
					@node((Label) { .text = "Pose", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((CapturePoseChooser) { });
					@node((Label) { .text = "at", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 44, .style = TEXT_FIELD_STYLE, .on_change = &capture_time_changed }).with_id(CAPTURE_TIME_ID);
					@node((Label) { .text = "s", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node(accent_button("Make reference", &capture_reference_clicked)).with_id("capture-reference");
				};
				@node((GenerateNote) { .text = reference_text, .size = ANIM_TEXT_SIZE, .color = has_reference ? TEXT : TEXT_DIM });
				if (has_reference)
				{
					@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
					{
						@node((Label) { .text = "Action", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
						@node((TextField) { .width = 230, .style = TEXT_FIELD_STYLE, .placeholder = "waves with his left hand",
							.on_change = &capture_action_changed }).with_id(CAPTURE_ACTION_ID);
						@node(panel_button("Copy prompt", &capture_copy_prompt_clicked)).with_id("capture-copy-prompt");
						@node(panel_button("Open folder", &capture_open_folder_clicked)).with_id("capture-open-folder");
					};
					@node((GenerateNote) { .text = "Give the video model reference.png as the first frame and the copied prompt (the action filled in). Keep it standing in place; a pose standing on both feet (an idle) starts best.",
						.size = 12, .color = TEXT_DIM });
				}

				// 3. The clip.
				@node((Label) { .text = "3 · Animate from video", .size = 14, .color = TEXT });
				@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
				{
					@node((Label) { .text = "Video", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 230, .style = TEXT_FIELD_STYLE, .placeholder = "the clip, or a folder of its frames",
						.on_change = &capture_video_changed }).with_id(CAPTURE_VIDEO_ID);
					@node(panel_button("Choose video…", &capture_choose_video_clicked)).with_id("capture-choose-video");
				};
				@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
				{
					@node((Label) { .text = "Name", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 160, .style = TEXT_FIELD_STYLE, .placeholder = "the video's file name",
						.on_change = &capture_name_changed }).with_id(CAPTURE_NAME_ID);
					@node(accent_button("Animate", &capture_animate_clicked)).with_id("capture-animate");
				};

				if (self.shown.running)
				{
					@tree((Wrap) { .gap_x = ANIM_GAP, .gap_y = 4, .cross_align = CENTER })
					{
						@node(panel_button("Stop", &capture_stop_clicked)).with_id("capture-stop");
						@node((Label) { .text = capture_stage_title(job), .size = ANIM_TEXT_SIZE, .color = TEXT });
					};
					@node((GenerateProgress) { .of = &capture_progress_of });
					@node((LiveLabel) { .text_of = &capture_status_text, .size = { 0, TREE_STYLE.row_height },
						.text_size = 12, .color = TEXT_DIM });
				}
				else if (self.shown.failed)
				{
					@node((GenerateNote) { .text = job.last(), .size = 12, .color = DOT_LOCKED });
				}
			}
		};
	};

	foreach (pair : (String[2][]){ { CAPTURE_POSES_ID, draft.poses }, { CAPTURE_TIME_ID, draft.pose_time },
		{ CAPTURE_ACTION_ID, draft.action }, { CAPTURE_VIDEO_ID, draft.video }, { CAPTURE_NAME_ID, draft.name } })
	{
		if (try Element* field = body.find_id(pair[0])) field.widget_as(TextField).set_text(field, pair[1]);
	}
	return body;
}

// ---------------------------------------------------------------------------
// Fields, kept in the draft as typed.

fn void capture_poses_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.capture_draft.poses, text);
fn void capture_time_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.capture_draft.pose_time, text);
fn void capture_action_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.capture_draft.action, text);
fn void capture_video_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.capture_draft.video, text);
fn void capture_name_changed(Ui* ui, String text) @private => replace_owned(&ui.inherit(AppState)!!.capture_draft.name, text);

// The chosen video, from the file chooser, into the draft and its field.
fn void set_capture_video(Ui* ui, String video)
{
	AppState* app = ui.inherit(AppState)!!;
	replace_owned(&app.capture_draft.video, video);
	ui.@each_id(CAPTURE_VIDEO_ID; field)
	{
		field.widget_as(TextField).set_text(field, video);
	};
}

fn void use_capture_finder_chosen(Ui* ui, String finder)
{
	AppState* app = ui.inherit(AppState)!!;
	if (catch err = app.use_capture_finder(finder))
	{
		app.@notice("Could not use that finder: %s", capture_fault_text(err));
		return;
	}
	app.capture_job.finished++;
	app.@notice("Using the joint finder %s", base_name(finder));
	refresh_capture_view(ui);
}

// ---------------------------------------------------------------------------
// The steps.

fn void capture_train_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	uint? poses = app.capture_draft.poses.trim().to_uint();
	if (catch poses) { app.@notice("Poses is a whole number, for example 1500."); return; }
	if (poses < 50 || poses > 20000) { app.@notice("Poses must be between 50 and 20000."); return; }
	if (catch err = app.start_capture_training(poses)) app.@notice("Could not start training: %s", capture_fault_text(err));
	refresh_capture_view(ui);
}

fn void capture_use_finder_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String finder = app.capture_finder();
	if (try slash = finder.rindex_of_char('/')) app.remember_directory(finder[:(usz)slash]);
	open_file_dialog(ui, FilePurpose.CAPTURE_FINDER);
}

fn void capture_reference_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (catch err = app.request_capture_reference()) app.@notice("Could not draw the reference: %s", capture_fault_text(err));
}

fn void capture_copy_prompt_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	ui.clipboard_write(app.capture_prompt());
	app.@notice(app.capture_draft.action.trim().len > 0 ? "Prompt copied, with the action filled in" : "Prompt copied · fill in the action where it says <describe the movement here>");
}

fn void capture_open_folder_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String folder = app.capture_path("studio");
	$if env::DARWIN:
		String opener = "open";
	$else
		String opener = "xdg-open";
	$endif
	Process? shown = process::spawn({ opener, folder });
	if (catch shown) { app.@notice("Could not open %s", folder); return; }
	(void)shown.destroy();
}

fn void capture_choose_video_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String video = app.capture_draft.video.trim();
	if (try slash = video.rindex_of_char('/')) app.remember_directory(video[:(usz)slash]);
	open_file_dialog(ui, FilePurpose.CAPTURE_VIDEO);
}

fn void capture_animate_clicked(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String name = app.capture_draft.name.trim();
	if (name.len == 0) name = capture_clip_name(app.capture_draft.video.trim());
	if (app.has_bound_clip_named(name))
	{
		app.@notice("The character already has a clip called \"%s\" — give this one another name.", name);
		return;
	}
	if (catch err = app.start_capture_animation()) app.@notice("Could not start: %s", capture_fault_text(err));
	refresh_capture_view(ui);
}

fn void capture_stop_clicked(Ui* ui) @private
{
	ui.inherit(AppState)!!.stop_capture();
	refresh_capture_view(ui);
}

fn String capture_stage_title(CaptureJob* job) @private
{
	switch (job.stage)
	{
		case RENDERING: return "Drawing the training set";
		case TRAINING: return "Training the joint finder";
		case EXTRACTING: return string::tformat("Reading \"%s\"'s frames", job.name);
		case ANIMATING: return string::tformat("Animating \"%s\"", job.name);
		default: return "Working";
	}
}

fn float capture_progress_of(Element* elem) @private => elem.inherit(AppState)!!.capture_job.progress();

fn String capture_status_text(Element* elem) @private
{
	CaptureJob* job = &elem.inherit(AppState)!!.capture_job;
	if (!job.running) return "".copy(mem);
	switch (job.stage)
	{
		case RENDERING: return string::format(mem, "Pose %d of %d", job.step, job.steps);
		case EXTRACTING: return job.steps > 0 ? string::format(mem, "Frame %d of %d", job.step, job.steps) : string::format(mem, "%d frames", job.step);
		default: return job.last().copy(mem);
	}
}

// ---------------------------------------------------------------------------
// The reference picture's pose: the rest pose, or a clip that plays on the rig.

<*
 The pose dropdown. Owns its labels and the clip each row names, as
 `GenerateGuideChooser` does. With nothing chosen yet it picks the first clip
 that sounds like standing (an idle), which starts a video best.
*>
struct CapturePoseChooser (Widget)
{
	String[] labels;
	String[] clips;
}

// The chooser on screen, whose rows a choice names; cleared when it goes.
CapturePoseChooser* capture_pose_shown;

fn void CapturePoseChooser.release(&self)
{
	foreach (label : self.labels) label.free(mem);
	foreach (clip : self.clips) if (clip.len > 0) clip.free(mem);
	if (self.labels.len > 0) alloc::free(mem, self.labels);
	if (self.clips.len > 0) alloc::free(mem, self.clips);
	self.labels = self.clips = {};
}

fn void CapturePoseChooser.unmount(&self, Element* elem) @dynamic
{
	if (capture_pose_shown == self) capture_pose_shown = null;
	self.release();
}

fn Element* CapturePoseChooser.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	capture_pose_shown = self;
	usz count = 1;
	foreach (usz p, &pack : app.packs)
	{
		foreach (usz c, &clip : pack.clips) if (app.clip_applies({ (int)p, (int)c })) count++;
	}
	self.labels = alloc::new_array(mem, String, (sz)count);
	self.clips = alloc::new_array(mem, String, (sz)count);
	self.labels[0] = "Rest pose".copy(mem);
	self.clips[0] = CAPTURE_REST.copy(mem);
	usz row = 1;
	usz idle = 0;
	foreach (usz p, &pack : app.packs)
	{
		foreach (usz c, &clip : pack.clips)
		{
			if (!app.clip_applies({ (int)p, (int)c })) continue;
			self.labels[row] = string::format(mem, "%s / %s", pack.name, clip.name);
			self.clips[row] = string::format(mem, "%s/%s", pack.name, clip.name);
			String lower = clip.name.to_lower_tcopy();
			if (idle == 0 && (lower.contains("idle") || lower.contains("stand"))) idle = row;
			row++;
		}
	}
	CaptureDraft* draft = &app.capture_draft;
	if (draft.pose_clip.len == 0) replace_owned(&draft.pose_clip, self.clips[idle]);
	usz selected = 0;
	foreach (usz i, clip : self.clips) if (clip == draft.pose_clip) selected = i;
	if (selected == 0 && draft.pose_clip != CAPTURE_REST) replace_owned(&draft.pose_clip, CAPTURE_REST);
	return @subtree(elem.ui)
	{
		@node((Select) { .options = self.labels, .selected = selected, .width = 200, .style = VIEW_MENU_STYLE,
			.searchable = self.labels.len > ANIM_CHOOSER_SEARCH_MIN, .on_change = &capture_pose_chosen }).with_id(CAPTURE_POSE_ID);
	};
}

fn Vec2 CapturePoseChooser.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}

fn void capture_pose_chosen(Ui* ui, usz row) @private
{
	if (!capture_pose_shown || row >= capture_pose_shown.clips.len) return;
	replace_owned(&ui.inherit(AppState)!!.capture_draft.pose_clip, capture_pose_shown.clips[row]);
}
