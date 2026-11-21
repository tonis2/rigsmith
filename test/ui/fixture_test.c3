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
// Fixture

<*
 A built interface over a fresh document.

 Opened through a pointer, never returned by value: `build_ui` hands the tree an
 `AppState*` that the viewport, the shortcuts and the HUD all keep, so moving
 the AppState after building leaves them reading dead stack. That is not a
 hypothetical — it is how the status line first shipped, and it rendered tofu.
*>
struct Fixture
{
	Ui* ui;
	crig::AppState app;

	// The viewport's element, looked up once. Hit-test assertions compare
	// against this pointer rather than asking the hit element what it is:
	// `widget_as` is an unchecked cast, so `elem.widget_as(Viewport) != null`
	// is true of every element in the tree and asserts nothing. It passed
	// happily with the panel laid over the whole window.
	Element* viewport;

	// `hud_text` builds the block's lines into the first and joins them into the
	// second. On the fixture because the joined slice is what the caller reads,
	// so it has to outlive the call that made it.
	char[512] hud_scratch;
	char[640] hud_joined;
}

<*
 Build the interface over `mesh`.

 **One fixture at a time.** `build_ui` re-initialises the module-global
 `area_layout` that every `AreaHost` points at, so two live fixtures would share
 one workspace and each rebuild would move the other's panes. A check that wants
 its own fixture has to open and close it while no other one is up.

 @param mesh : `The model to rig. An empty one is the state crig opens in with no file.`
*>
fn void? Fixture.open(&self, rig::TriMesh mesh = cube())
{
	rig::TriMesh shared = cube();
	bool is_shared_cube = mesh.positions.ptr == shared.positions.ptr
		&& mesh.indices.ptr == shared.indices.ptr;
	self.app = is_shared_cube ? shared_app::open() : crig::new_app(mesh);
	if (!is_shared_cube) shared_app::attach_library(&self.app);
	// The app opens with the N-panel closed; these checks are about what is in it,
	// so the fixture opens it.
	self.app.show_joint_panel = true;
	self.ui = cui::new_ui({ crig::WIN_W, crig::WIN_H });

	// Required, not best-effort. Glyph metrics size the menu titles and the
	// Controls sheet, and a fontless run lays both out at zero — every geometric
	// check below would then pass without touching the thing it names.
	// Through `shared_app`, which hands the fixture an atlas the process baked
	// once rather than letting every check's first flush bake its own.
	shared_app::load_font(self.ui)!;

	// `shared_app` gives this fresh state one configured library and its own
	// mutable index, but borrows the immutable packs read once for the process.
	// Checks specifically about rescanning still call `scan_libraries` themselves
	// and detach into fully owned data; ordinary pointer checks do not reopen the
	// same glTF files hundreds of times.

	// One pane, unlike the app, which opens with the library beside the model.
	// Nearly every check below aims at pixels in a full-width viewport, counts
	// the panes a gesture produced, or asserts the tree is back to one leaf —
	// all of which are about splitting *from* a single pane. The workspace the
	// app opens on is checked in the_default_workspace_opens_three_panes.
	crig::build_ui(self.ui, &self.app, false);
	self.ui.flush(); // hit testing reads absolute origins, which emit writes

	self.viewport = self.ui.find(Viewport)!;
}

fn void Fixture.close(&self)
{
	self.ui.free();
	self.app.free();

	// The area layout is a module global that `build_ui` re-initialises, so no
	// element in the tree owns the node tree it allocated. The app never has to
	// release it — it lives as long as the process — but a fixture opened and
	// closed once per check does.
	crig::area_layout.free();
}

fn RigDocument* Fixture.doc(&self) => &self.app.doc;

// ---------------------------------------------------------------------------
// Look-ups the checks share

// The middle of an element, in window coordinates: where a click on it goes.
fn Vec2 centre_of(Element* elem) => elem.absolute + elem.size * 0.5f;

// The middle of the element `id`.
fn Vec2 id_centre(Fixture* f, String id) => centre_of(f.ui.find_id(id)!!);

// Which child of `root` holds the element `id`, or -1.
fn sz root_place(Ui* ui, Element* root, String id)
{
	Element*? found = ui.find_id(id);
	if (catch found) return -1;
	Element* at = found;
	while (at && at.parent != root) at = at.parent;
	foreach (usz i, child : root.children.array_view()) if (child == at) return (sz)i;
	return -1;
}

// Replace the text of the field `id` with `text` and press Return.
fn void type_field(Fixture* f, String id, String text)
{
	Element* field = f.ui.find_id(id)!!;
	field.widget_as(TextField).set_text(field, "");
	f.type_into(field, text);
	f.feed_key(Key.RETURN);
	f.feed(f.ui.input.mouse);
}

// The Animations dock in a pane under the model, showing the first cutscene, one frame later.
fn void show_cutscene_tab(Fixture* f)
{
	crig::show_pane_view(f.ui, crig::ANIMATION_VIEW, SplitAxis.VERTICAL, 0.5f);
	(void)f.app.show_cutscene(0);
	f.ui.flush();
	f.feed(f.ui.input.mouse);
}

// The editing clip's layer `at`.
fn AnimLayer* layer_at(Fixture* f, usz at) => &f.app.clip(f.app.editing).layers[at];

<*
 Place a dot in the middle of the model unless there is already one.

 Each check gets a fixture of its own, so a check that wants a dot to work on
 has to put it there — nothing runs before it to leave one behind. Placed by
 clicking rather than by reaching into the document, so what these checks
 operate on is a dot a user could have made.
*>
fn void Fixture.ensure_a_dot(&self)
{
	if (self.doc().dots.len() > 0) return;
	self.click(VIEWPORT_CENTER);
	test::@check(self.doc().dots.len() > 0, "a click in the middle of the model placed no dot");
}
