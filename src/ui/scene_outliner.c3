<*
 The spatial contents of crig's current document.

 The source importer still flattens geometry into one `TriMesh`, so this is the
 honest logical hierarchy: one model, one mesh, one skeleton, and its joints.
 Animations belong to their existing views and are deliberately absent here.
*>
module crig;

import cui;
import cui::widgets;
import rig;
import std::core::string;
import std::math::vector;

const String SCENE_OUTLINER_ID = "scene-outliner";
const float SCENE_OUTLINER_PAD = 4.0f;

// The outliner's icons, by the number a TreeRow carries. Painted by
// `paint_outliner_icon`; zero is cui's "no icon".
const ushort OUTLINER_ICON_SCENE = 1;
const ushort OUTLINER_ICON_MODEL = 2;
const ushort OUTLINER_ICON_MESH = 3;
const ushort OUTLINER_ICON_SKELETON = 4;
const ushort OUTLINER_ICON_JOINT = 5;
const ushort OUTLINER_ICON_ROOT = 6;
const ushort OUTLINER_ICON_EYE = 7;

// Blender's object orange and mesh-data green, so the rows read as the same kinds.
const Color OUTLINER_MODEL_INK = { 0.93, 0.56, 0.22, 1.0 };
const Color OUTLINER_MESH_INK = { 0.35, 0.80, 0.62, 1.0 };
const Color OUTLINER_BONE_INK = { 0.78, 0.80, 0.86, 1.0 };

enum SceneItemKind : int
{
	SCENE_ITEM,
	MODEL_ITEM,
	MESH_ITEM,
	SKELETON_ITEM,
	JOINT_ITEM,
}

struct SceneOutlinerItem
{
	SceneItemKind kind;
	uint dot_id;
	usz depth;
	bool expandable;
	bool expanded;
}

fn bool AppState.outliner_joint_collapsed(&self, uint id)
{
	foreach (held : self.outliner_collapsed_joints.array_view()) if (held == id) return true;
	return false;
}

fn void AppState.toggle_outliner_joint(&self, uint id)
{
	foreach (sz i, held : self.outliner_collapsed_joints.array_view())
	{
		if (held != id) continue;
		self.outliner_collapsed_joints.remove_at(i);
		return;
	}
	self.outliner_collapsed_joints.push(id);
}

fn SceneOutlinerItem[] scene_outliner_items(AppState* app) @private
{
	usz dots = (usz)app.doc.dots.len();
	SceneOutlinerItem[] items = alloc::new_array(mem, SceneOutlinerItem, (sz)dots + 4);
	usz count = 0;
	bool has_model = app.has_mesh() || dots > 0;

	items[count++] = {
		.kind = SCENE_ITEM,
		.depth = 0,
		.expandable = has_model,
		.expanded = !app.outliner_scene_collapsed,
	};
	if (!has_model || app.outliner_scene_collapsed) return items[:count];

	items[count++] = {
		.kind = MODEL_ITEM,
		.depth = 1,
		.expandable = app.has_mesh() || dots > 0,
		.expanded = !app.outliner_model_collapsed,
	};
	if (app.outliner_model_collapsed) return items[:count];

	if (app.has_mesh()) items[count++] = { .kind = MESH_ITEM, .depth = 2 };
	if (dots == 0) return items[:count];

	items[count++] = {
		.kind = SKELETON_ITEM,
		.depth = 2,
		.expandable = true,
		.expanded = !app.outliner_skeleton_collapsed,
	};
	if (app.outliner_skeleton_collapsed) return items[:count];

	uint[] dot_ids;
	rig::Skeleton? built = build_skeleton(&app.doc, mem, &dot_ids);
	if (catch built) return items[:count];
	rig::Skeleton skeleton = built;
	defer
	{
		skeleton.free(mem);
		if (dot_ids.len > 0) alloc::free(mem, dot_ids);
	}

	// Depth-first, each joint straight after its parent and before the next
	// sibling. The skeleton stores joints breadth-first — every depth-2 joint,
	// then every depth-3 one — which drawn indented put all the fingers' third
	// segments under the last second segment listed.
	foreach (usz joint, int parent : skeleton.parents)
	{
		if (parent < 0) count = add_outliner_joint(app, &skeleton, dot_ids, joint, 3, items, count);
	}

	return items[:count];
}

fn usz add_outliner_joint(AppState* app, rig::Skeleton* skeleton, uint[] dot_ids, usz joint, usz depth,
	SceneOutlinerItem[] items, usz count) @private
{
	bool has_child = false;
	foreach (other_parent : skeleton.parents)
	{
		if (other_parent != (int)joint) continue;
		has_child = true;
		break;
	}
	bool expanded = has_child && !app.outliner_joint_collapsed(dot_ids[joint]);
	items[count++] = {
		.kind = JOINT_ITEM,
		.dot_id = dot_ids[joint],
		.depth = depth,
		.expandable = has_child,
		.expanded = expanded,
	};
	if (!expanded) return count;
	foreach (usz child, int parent : skeleton.parents)
	{
		if (parent == (int)joint) count = add_outliner_joint(app, skeleton, dot_ids, child, depth + 1, items, count);
	}
	return count;
}

fn bool scene_outliner_item_at(AppState* app, usz row, SceneOutlinerItem* out) @private
{
	SceneOutlinerItem[] items = scene_outliner_items(app);
	defer if (items.len > 0) alloc::free(mem, items);
	if (row >= items.len) return false;
	*out = items[row];
	return true;
}

fn SceneSelection scene_selection_of(SceneItemKind kind) @private
{
	switch (kind)
	{
		case SCENE_ITEM: return SCENE;
		case MODEL_ITEM: return MODEL;
		case MESH_ITEM: return MESH;
		case SKELETON_ITEM: return SKELETON;
		case JOINT_ITEM: return JOINT;
	}
}

fn bool scene_item_selected(AppState* app, SceneOutlinerItem item) @private
{
	if (item.kind == JOINT_ITEM) return app.selected == item.dot_id;
	if (app.selected != 0) return false;
	return app.scene_selection == scene_selection_of(item.kind);
}

fn ushort scene_item_icon(AppState* app, SceneOutlinerItem item) @private
{
	switch (item.kind)
	{
		case SCENE_ITEM: return OUTLINER_ICON_SCENE;
		case MODEL_ITEM: return OUTLINER_ICON_MODEL;
		case MESH_ITEM: return OUTLINER_ICON_MESH;
		case SKELETON_ITEM: return OUTLINER_ICON_SKELETON;
		case JOINT_ITEM: return item.dot_id == app.doc.root_id ? OUTLINER_ICON_ROOT : OUTLINER_ICON_JOINT;
	}
}

<*
 The eye a row carries, if it has one: the model's is on while either half of
 it shows, the mesh's and the skeleton's are the View menu's own switches.
*>
fn TreeToggle scene_item_eye(AppState* app, SceneOutlinerItem item) @private
{
	switch (item.kind)
	{
		case MODEL_ITEM: return { .icon = OUTLINER_ICON_EYE, .on = app.show_mesh || app.show_rig, .shown = true };
		case MESH_ITEM: return { .icon = OUTLINER_ICON_EYE, .on = app.show_mesh, .shown = true };
		case SKELETON_ITEM: return { .icon = OUTLINER_ICON_EYE, .on = app.show_rig, .shown = true };
		default: return {};
	}
}

// A closed outline triangle, point down — Blender's object mark.
fn void paint_outline_triangle(Painter* painter, Vec2 a, Vec2 b, Vec2 c, float thickness, Color ink) @private
{
	painter.line(a, b, thickness, ink);
	painter.line(b, c, thickness, ink);
	painter.line(c, a, thickness, ink);
}

<*
 Draws the outliner's icons with the painter's shapes — cui has no icon set, so
 each is a few strokes, the way the tool column's are.
*>
fn void paint_outliner_icon(Painter* painter, Vec2 at, float size, ushort icon, bool dim)
{
	float r = size * 0.5f;
	switch (icon)
	{
		case OUTLINER_ICON_SCENE:
			// A box with a lid: a collection.
			painter.rect({ at.x - r, at.y - r * 0.7f }, { size, r * 1.7f },
				{ .border_color = TEXT_DIM, .border_width = 1.5f, .border_radius = { 2, 2, 2, 2 } });
			painter.line({ at.x - r, at.y - r * 0.2f }, { at.x + r, at.y - r * 0.2f }, 1.5f, TEXT_DIM);
		case OUTLINER_ICON_MODEL:
			paint_outline_triangle(painter,
				{ at.x - r, at.y - r * 0.75f }, { at.x + r, at.y - r * 0.75f }, { at.x, at.y + r * 0.9f },
				2.0f, OUTLINER_MODEL_INK);
		case OUTLINER_ICON_MESH:
			Vec2 a = { at.x - r * 0.85f, at.y - r * 0.6f };
			Vec2 b = { at.x + r * 0.85f, at.y - r * 0.6f };
			Vec2 c = { at.x, at.y + r * 0.85f };
			paint_outline_triangle(painter, a, b, c, 1.3f, OUTLINER_MESH_INK);
			painter.circle(a, 2.0f, { .color = OUTLINER_MESH_INK });
			painter.circle(b, 2.0f, { .color = OUTLINER_MESH_INK });
			painter.circle(c, 2.0f, { .color = OUTLINER_MESH_INK });
		case OUTLINER_ICON_SKELETON:
			// A bone: a shaft with a knuckle at each end.
			Vec2 a = { at.x - r * 0.55f, at.y + r * 0.55f };
			Vec2 b = { at.x + r * 0.55f, at.y - r * 0.55f };
			painter.line(a, b, 2.5f, OUTLINER_BONE_INK);
			painter.circle(a + { -1.5f, 0.0f }, 2.2f, { .color = OUTLINER_BONE_INK });
			painter.circle(a + { 0.0f, 1.5f }, 2.2f, { .color = OUTLINER_BONE_INK });
			painter.circle(b + { 1.5f, 0.0f }, 2.2f, { .color = OUTLINER_BONE_INK });
			painter.circle(b + { 0.0f, -1.5f }, 2.2f, { .color = OUTLINER_BONE_INK });
		case OUTLINER_ICON_JOINT:
		case OUTLINER_ICON_ROOT:
			// The overlay's own dot, so a row and the joint it names look alike.
			painter.circle(at, r * 0.5f, {
				.color = icon == OUTLINER_ICON_ROOT ? DOT_ROOT : DOT,
				.border_color = DOT_OUTLINE,
				.border_width = 1.0f,
			});
		case OUTLINER_ICON_EYE:
			Color ink = dim ? { 0.40, 0.42, 0.50, 1.0 } : TEXT;
			if (dim)
			{
				// Shut: the lower lid and its lashes.
				painter.arc(at + { 0.0f, -r * 0.55f }, r * 0.9f, 0.55f, 2.03f, 1.5f, ink);
				painter.line({ at.x - r * 0.35f, at.y + r * 0.3f }, { at.x - r * 0.5f, at.y + r * 0.6f }, 1.2f, ink);
				painter.line({ at.x + r * 0.35f, at.y + r * 0.3f }, { at.x + r * 0.5f, at.y + r * 0.6f }, 1.2f, ink);
				return;
			}
			painter.ellipse(at, { r * 0.95f, r * 0.55f }, { .border_color = ink, .border_width = 1.5f });
			painter.circle(at, r * 0.28f, { .color = ink });
		default:
	}
}

fn void scene_outliner_chosen(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	SceneOutlinerItem item;
	if (!scene_outliner_item_at(app, row, &item)) return;

	if (item.kind == JOINT_ITEM)
	{
		bool shift = ui.input.shift_down();
		if (shift) { app.extend_selection(item.dot_id); }
		else { app.select(item.dot_id); }
	}
	else
	{
		app.select_scene(scene_selection_of(item.kind));
	}
	app.refresh_ui();
}

<*
 A right-click on a row: pick what it names — a joint already in a group keeps
 the group — then raise the context menu for it at the press.
*>
fn void scene_outliner_context(Ui* ui, usz row, Vec2 at) @private
{
	AppState* app = ui.inherit(AppState)!!;
	SceneOutlinerItem item;
	if (!scene_outliner_item_at(app, row, &item)) return;

	if (item.kind == JOINT_ITEM)
	{
		if (!app.is_selected(item.dot_id)) app.select(item.dot_id);
	}
	else
	{
		app.select_scene(scene_selection_of(item.kind));
	}
	app.refresh_ui();
	open_viewport_context(ui, at);
}

<*
 The eye on a row: shows or hides that part without selecting it. The model's
 eye hides both halves while either shows, and brings both back otherwise.
*>
fn void scene_outliner_eye(Ui* ui, usz row, usz column) @private
{
	AppState* app = ui.inherit(AppState)!!;
	SceneOutlinerItem item;
	if (!scene_outliner_item_at(app, row, &item)) return;

	switch (item.kind)
	{
		case MODEL_ITEM:
			bool show = !(app.show_mesh || app.show_rig);
			app.show_mesh = show;
			app.show_rig = show;
			app.refresh_ui();
		case MESH_ITEM: menu_show_mesh(ui);
		case SKELETON_ITEM: menu_show_rig(ui);
		default: return;
	}
}

fn void scene_outliner_toggled(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	SceneOutlinerItem item;
	if (!scene_outliner_item_at(app, row, &item) || !item.expandable) return;

	switch (item.kind)
	{
		case SCENE_ITEM: app.outliner_scene_collapsed = !app.outliner_scene_collapsed;
		case MODEL_ITEM: app.outliner_model_collapsed = !app.outliner_model_collapsed;
		case SKELETON_ITEM: app.outliner_skeleton_collapsed = !app.outliner_skeleton_collapsed;
		case JOINT_ITEM: app.toggle_outliner_joint(item.dot_id);
		case MESH_ITEM: return;
	}

	ui.@each(SceneOutliner; outliner) { outliner.request_build(); };
}

struct SceneOutlinerSnapshot
{
	uint geometry_generation;
	uint revision;
	char* source_ptr;
	usz source_len;
	uint selected;
	uint root_id;
	usz dots;
	usz edges;
	usz selected_count;
	usz collapsed_joints;
	// Which dots are selected, folded to a number: a group swapped for another of
	// the same size under the same anchor still has to re-highlight.
	ulong selection_sum;
	SceneSelection selection;
	bool show_mesh;
	bool show_rig;
	bool scene_collapsed;
	bool model_collapsed;
	bool skeleton_collapsed;
}

fn ulong scene_selection_sum(AppState* app) @private
{
	ulong sum = 0;
	foreach (id : app.also_selected.array_view()) sum += (ulong)id * 2654435761u + 1;
	return sum;
}

fn SceneOutlinerSnapshot scene_outliner_snapshot(AppState* app) @private
{
	return {
		.geometry_generation = app.geometry_generation,
		.revision = app.undo_stack.revision,
		.source_ptr = app.source_path.ptr,
		.source_len = app.source_path.len,
		.selected = app.selected,
		.root_id = app.doc.root_id,
		.dots = (usz)app.doc.dots.len(),
		.edges = (usz)app.doc.edges.len(),
		.selected_count = app.selection_count(),
		.collapsed_joints = (usz)app.outliner_collapsed_joints.len(),
		.selection_sum = scene_selection_sum(app),
		.selection = app.scene_selection,
		.show_mesh = app.show_mesh,
		.show_rig = app.show_rig,
		.scene_collapsed = app.outliner_scene_collapsed,
		.model_collapsed = app.outliner_model_collapsed,
		.skeleton_collapsed = app.outliner_skeleton_collapsed,
	};
}

fn bool SceneOutlinerSnapshot.differs(self, SceneOutlinerSnapshot other)
{
	return self.geometry_generation != other.geometry_generation
		|| self.revision != other.revision
		|| self.source_ptr != other.source_ptr
		|| self.source_len != other.source_len
		|| self.selected != other.selected
		|| self.root_id != other.root_id
		|| self.dots != other.dots
		|| self.edges != other.edges
		|| self.selected_count != other.selected_count
		|| self.collapsed_joints != other.collapsed_joints
		|| self.selection_sum != other.selection_sum
		|| self.selection != other.selection
		|| self.show_mesh != other.show_mesh
		|| self.show_rig != other.show_rig
		|| self.scene_collapsed != other.scene_collapsed
		|| self.model_collapsed != other.model_collapsed
		|| self.skeleton_collapsed != other.skeleton_collapsed;
}

struct SceneOutliner (Widget)
{
	SceneOutlinerSnapshot shown;
	SceneOutlinerItem[] items;
	TreeRow[] rows;
}

fn void SceneOutliner.release(&self)
{
	foreach (row : self.rows)
	{
		if (row.label.len > 0) alloc::free(mem, row.label.ptr);
		if (row.trailing.len > 0) alloc::free(mem, row.trailing.ptr);
	}
	if (self.rows.len > 0) alloc::free(mem, self.rows);
	if (self.items.len > 0) alloc::free(mem, self.items);
	self.rows = {};
	self.items = {};
}

fn void SceneOutliner.unmount(&self, Element* elem) @dynamic => self.release();

fn void SceneOutliner.refresh(&self, Element* elem, AppState* app)
{
	SceneOutlinerSnapshot now = scene_outliner_snapshot(app);
	if (!self.shown.differs(now)) return;
	elem.request_build();
}

fn void SceneOutliner.update(&self, Element* elem, float dt) @dynamic
{
	self.refresh(elem, elem.inherit(AppState)!!);
}

fn Element* SceneOutliner.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	self.shown = scene_outliner_snapshot(app);
	self.items = scene_outliner_items(app);
	self.rows = alloc::new_array(mem, TreeRow, (sz)self.items.len);
	usz selected = self.items.len;

	foreach (usz i, item : self.items)
	{
		String label;
		String trailing;
		switch (item.kind)
		{
			case SCENE_ITEM: label = "Scene".copy(mem);
			case MODEL_ITEM:
				label = (app.source_path.len > 0 ? base_name(app.source_path) : "Model").copy(mem);
			case MESH_ITEM:
				label = "Mesh".copy(mem);
				trailing = string::format(mem, "%d verts", app.geometry.positions.len);
			case SKELETON_ITEM:
				label = "Skeleton".copy(mem);
				trailing = string::format(mem, "%d joints", app.doc.dots.len());
			case JOINT_ITEM:
				Dot* dot = app.doc.find(item.dot_id);
				label = dot && dot.name.len > 0
					? dot.name.copy(mem)
					: string::format(mem, "Joint %d", item.dot_id);
		}

		self.rows[i] = {
			.label = label,
			.trailing = trailing,
			.depth = item.depth,
			.expandable = item.expandable,
			.expanded = item.expanded,
			.icon = scene_item_icon(app, item),
			.highlighted = item.kind == JOINT_ITEM && app.is_selected(item.dot_id),
		};
		self.rows[i].toggles[0] = scene_item_eye(app, item);
		if (scene_item_selected(app, item)) selected = i;
	}

	return @subtree(elem.ui)
	{
		@node((Tree) {
			.rows = self.rows,
			.selected = selected,
			.on_select = &scene_outliner_chosen,
			.on_toggle = &scene_outliner_toggled,
			.on_context = &scene_outliner_context,
			.on_row_toggle = &scene_outliner_eye,
			.paint_icon = &paint_outliner_icon,
			.style = OUTLINER_STYLE,
		});
	};
}

fn Vec2 SceneOutliner.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ constraints.max.x, 0 });
	Vec2 inner = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ constraints.max.x, inner.y });
}

fn Element* build_scene_view(Ui* ui)
{
	return @subtree(ui)
	{
		@tree((Scroll) { })
		{
			@tree((Padding) { .insets = widgets::insets_all(SCENE_OUTLINER_PAD) })
			{
				@node((SceneOutliner) { }).with_id(SCENE_OUTLINER_ID);
			};
		};
	};
}
