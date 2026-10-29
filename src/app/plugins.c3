<*
 The llm folder's plugins from Rigsmith's side: what it holds, and linking a
 plugin's folder in or out. The folder itself is `llm_plugins_directory`
 (`app/generate.c3`); the rules are the library's (`llm::pipeline`, plugins.c3).
 Settings › AI › Plugins and the `plugins` MCP tool both come through here.
*>
module crig;

import llm::pipeline;
import cui::widgets;
import std::io;
import std::io::path;

<*
 Link the plugin at `folder` into the plugins folder.

 @return? llm::pipeline::NOT_A_PLUGIN : `The folder has no plugin.json or main.js.`
 @return? llm::pipeline::PLUGIN_EXISTS : `The plugins folder already has one by that name.`
 @return? llm::pipeline::LINK_FAILED : `The link could not be made: the folder is read-only, say.`
 @return `The plugin's name. Temporary.`
*>
fn String? AppState.link_llm_plugin(&self, String folder)
{
	String root = self.llm_plugins_directory();
	defer alloc::free(mem, root.ptr);
	return llm::pipeline::link_plugin(root, folder);
}

<*
 Take a linked plugin out of the plugins folder; its own folder stays.

 @return? llm::pipeline::PLUGIN_NOT_LINKED : `No such plugin, or it is not a link (a real folder is never deleted).`
 @return? llm::pipeline::LINK_FAILED : `The link could not be removed.`
*>
fn void? AppState.unlink_llm_plugin(&self, String name)
{
	String root = self.llm_plugins_directory();
	defer alloc::free(mem, root.ptr);
	llm::pipeline::unlink_plugin(root, name)!;
}

fn String plugin_fault_text(fault err)
{
	switch (err)
	{
		case llm::pipeline::NOT_A_PLUGIN: return "that folder is not a plugin — it needs a plugin.json and a main.js";
		case llm::pipeline::PLUGIN_EXISTS: return "the plugins folder already has a plugin by that name";
		case llm::pipeline::PLUGIN_NOT_LINKED: return "only a linked plugin can be unlinked — a plugin folder that is really there is left alone";
		case llm::pipeline::LINK_FAILED: return "the link could not be made or removed — is the plugins folder writable?";
		default: return "the plugins folder could not be changed";
	}
}

<*
 The plugins, for the settings list: re-read from disk, so a plugin linked
 from outside Rigsmith shows too. Rows borrow `plugin_list`'s strings.
*>
fn void AppState.refresh_plugin_rows(&self)
{
	self.free_plugin_rows();
	String root = self.llm_plugins_directory();
	defer alloc::free(mem, root.ptr);
	self.plugin_list = llm::pipeline::list_plugins(mem, root);
	if (self.plugin_list.len == 0) return;
	self.plugin_rows = alloc::new_array(mem, TreeRow, (sz)self.plugin_list.len);
	foreach (usz i, p : self.plugin_list)
	{
		self.plugin_rows[i] = {
			.label = p.name,
			// Where a linked one really is, else its version; a broken one says why.
			.trailing = p.error.len > 0 ? p.error : p.linked ? p.target : p.version,
		};
	}
}

fn void AppState.free_plugin_rows(&self)
{
	if (self.plugin_rows.len > 0) alloc::free(mem, self.plugin_rows);
	self.plugin_rows = {};
	llm::pipeline::free_plugins(mem, self.plugin_list);
	self.plugin_list = {};
}
