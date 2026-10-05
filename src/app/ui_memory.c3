<*
 What the interface remembers between runs: which N-panel tab was open and which
 Disclosure sections were folded, kept in the config beside the Animations dock's
 split (`anim_layers_ratio`).

 The live state stays on the AppState as plain bools, because that is what the
 panels read each build. This file only copies it to and from the config: once at
 startup (`restore_ui_memory`) and whenever a tab or a section changes
 (`remember_ui`).
*>
module crig;

// One bit of `CrigConfig.folded_sections` per Disclosure section. Append only:
// the numbers are in people's config files.
enum FoldedSection : int
{
	JOINT_INFO,
	ALIGN_INFO,
	WEIGHTS_INFO,
	POSE_INFO,
	POSE_OPTIONS,
	POSE_LIBRARY,
	LAYER_BLEND,
	LAYER_MOTION,
	LAYER_MASK,
}

const int FOLDED_SECTIONS = 9;

fn bool* AppState.folded_flag(&self, FoldedSection section)
{
	switch (section)
	{
		case JOINT_INFO: return &self.joint_info_collapsed;
		case ALIGN_INFO: return &self.align_info_collapsed;
		case WEIGHTS_INFO: return &self.weights_info_collapsed;
		case POSE_INFO: return &self.pose_info_collapsed;
		case POSE_OPTIONS: return &self.pose_options_collapsed;
		case POSE_LIBRARY: return &self.pose_library_collapsed;
		case LAYER_BLEND: return &self.layer_blend_collapsed;
		case LAYER_MOTION: return &self.layer_motion_collapsed;
		case LAYER_MASK: return &self.layer_mask_collapsed;
	}
}

<*
 Adopt the config's remembered tab and folded sections. Called once, right after
 the config is read; a config with none leaves every section open on Joint.
*>
fn void AppState.restore_ui_memory(&self)
{
	int tab = self.config.joint_panel_tab;
	if (tab >= 0 && tab <= JointPanelTab.POSE.ordinal) self.joint_panel_tab = (JointPanelTab)tab;
	for (int i = 0; i < FOLDED_SECTIONS; i++)
	{
		*self.folded_flag((FoldedSection)i) = (self.config.folded_sections & (1u << i)) != 0;
	}
}

<*
 Write the tab and the folded sections into the config and save it. Cheap enough
 to call from every tab or section click.
*>
fn void AppState.remember_ui(&self)
{
	uint bits = 0;
	for (int i = 0; i < FOLDED_SECTIONS; i++)
	{
		if (*self.folded_flag((FoldedSection)i)) bits |= 1u << i;
	}
	if (bits == self.config.folded_sections && (int)self.joint_panel_tab == self.config.joint_panel_tab) return;
	self.config.folded_sections = bits;
	self.config.joint_panel_tab = (int)self.joint_panel_tab.ordinal;
	self.config.save();
}
