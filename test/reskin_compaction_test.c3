module crig_tests::reskin_compaction;

import gltf_edit;
import gltf;
import crig;
import rig;
import std::core::test;
import std::io::file;
import std::math;
import std::math::matrix;
import std::math::vector;

const String COMPACT_JSON = `{
 "asset": {"version":"2.0"}, "scene":0, "scenes":[{"nodes":[0,1]}],
 "nodes":[{"mesh":0,"skin":0},{"name":"root"}],
 "meshes":[{"primitives":[{"attributes":{"POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2, "NORMAL": 4 },"indices":3,"targets":[{"POSITION":5 }],"material":0}]}],
 "materials":[{"name":"keep material","pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
 "textures":[{"source":0}], "images":[{"bufferView":7,"mimeType":"image/png"}],
 "skins":[{"joints":[1],"skeleton":1,"inverseBindMatrices":6}],
 "accessors":[
 {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,1]},
 {"bufferView":1,"componentType":5121,"count":3,"type":"VEC4"},
 {"bufferView":2,"componentType":5126,"count":3,"type":"VEC4"},
 {"bufferView":3,"componentType":5123,"count":3,"type":"SCALAR"},
 {"bufferView":4,"componentType":5126,"count":3,"type":"VEC3"},
 {"componentType":5126,"count":3,"type":"VEC3","sparse":{"count":3,"indices":{"bufferView":5,"componentType":5121},"values":{"bufferView":6}}},
 {"bufferView":8,"componentType":5126,"count":1,"type":"MAT4"}],
 "bufferViews":[
 {"buffer":0,"byteOffset":0,"byteLength":36},
 {"buffer":0,"byteOffset":36,"byteLength":12},
 {"buffer":0,"byteOffset":48,"byteLength":48},
 {"buffer":0,"byteOffset":96,"byteLength":6},
 {"buffer":0,"byteOffset":104,"byteLength":36},
 {"buffer":0,"byteOffset":140,"byteLength":3},
 {"buffer":0,"byteOffset":144,"byteLength":36},
 {"buffer":0,"byteOffset":180,"byteLength":68},
 {"buffer":0,"byteOffset":248,"byteLength":64}],
 "buffers":[{"byteLength":312}], "extras":{"keep":"custom metadata"}
}`;

fn void put_u32(char[] bytes, usz offset, uint value)
{
	for (usz i = 0; i < 4; i++) bytes[offset + i] = (char)((value >> (i * 8)) & 255);
}

fn void fixture(String path)
{
	char[] rest = alloc::new_array(mem, char, 320);
	defer alloc::free(mem, rest);
	put_u32(rest, 0, 312);
	put_u32(rest, 4, 0x004e4942);
	// Valid triangle geometry and skinning, with sparse morph data and a PNG.
	// Compare each semantic payload independently of the writer's index mapping.
	float[9] positions = {0,0,0, 1,0,0, 0,1,0};
	for (usz i = 0; i < positions.len; i++) put_u32(rest,8 + i*4,bitcast(positions[i],uint));
	for (usz i = 0; i < 3; i++)
	{
		put_u32(rest,8 + 48 + i*16,bitcast(1.0f,uint));
		rest[8 + 96 + i*2] = (char)i;
		put_u32(rest,8 + 104 + i*12 + 8,bitcast(1.0f,uint));
		rest[8 + 140 + i] = (char)i;
		put_u32(rest,8 + 144 + i*12,bitcast(0.125f,uint));
	}
	for (usz i = 0; i < 4; i++) put_u32(rest,8 + 248 + i*20,bitcast(1.0f,uint));
	const char[68] PNG = {
		137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,
		8,4,0,0,0,181,28,12,2,0,0,0,11,73,68,65,84,120,218,99,100,
		248,15,0,1,5,1,1,39,24,227,102,0,0,0,0,73,69,78,68,174,66,96,130
	};
	rest[188:68] = PNG[..];
	gltf_edit::write_glb(path, { .json = (char[])COMPACT_JSON, .rest = rest, .version = 2, .binary = true })!!;
}

fn usz number(String text, gltf_edit::JsonStep[] path)
{
	return (usz)gltf_edit::read_gltf_member(text, path).to_int()!!;
}

fn char[] view_bytes(gltf_edit::GlbParts* parts, usz view)
{
	String text = (String)parts.json;
	usz offset = number(text, {{.key="bufferViews"},{.at=view},{.key="byteOffset"}});
	usz length = number(text, {{.key="bufferViews"},{.at=view},{.key="byteLength"}});
	return parts.rest[8 + offset:length];
}

fn usz attr_view(String text, String attr)
{
	usz accessor = number(text, {{.key="meshes"},{.at=0},{.key="primitives"},{.at=0},{.key="attributes"},{.key=attr}});
	return number(text, {{.key="accessors"},{.at=accessor},{.key="bufferView"}});
}

fn void check_bytes(char[] a, char[] b)
{
	test::eq(a.len, b.len);
	foreach (i, value : a) test::eq(value, b[i]);
}

fn usz array_count(String text, String name)
{
	String raw = gltf_edit::read_gltf_member(text, {{.key=name}});
	String[] entries = gltf_edit::json_array_items(mem, raw)!!;
	defer alloc::free(mem, entries);
	return entries.len;
}

fn void? rewrite(String path, bool animated = false)
{
	gltf_edit::ReskinJoint[1] joints = {{ .name = "root", .parent = -1 }};
	gltf_edit::ReskinPart[1] parts = {{ .node = 0, .mesh = 0, .primitive = 0, .count = 3 }};
	float[3] weights = {1,1,1};
	float[2] times = {0,1};
	Vec3[2] slides = {{0,0,0},{1,0,0}};
	gltf_edit::ReskinCurve[1] curves = {{.joint=0,.slides=slides[..]}};
	gltf_edit::ReskinClip[1] clips = {{.name="move",.times=times[..],.curves=curves[..]}};
	gltf_edit::reskin_glb(mem, path, {
		.joints=joints[..],.parts=parts[..],.weights=weights[..],.vertices=3,
		.skin=0,.bind=matrix::IDENTITY4,.clips=animated ? clips[..] : (gltf_edit::ReskinClip[]){}
	})!;
}

fn void repeated_reskin_reclaims_interleaved_data_and_preserves_other_payload() @test
{
	String path = "build/reskin-compaction.glb";
	fixture(path);
	defer (void)file::delete(path);
	gltf_edit::GlbParts before = gltf_edit::split_glb(mem,path)!!;
	defer before.free(mem);
	rewrite(path)!!;
	gltf_edit::GlbParts first = gltf_edit::split_glb(mem,path)!!;
	defer first.free(mem);
	String text = (String)first.json;
	test::eq(array_count(text,"accessors"),(usz)7);
	test::eq(array_count(text,"bufferViews"),(usz)9);
	check_bytes(view_bytes(&before,0),view_bytes(&first,attr_view(text,"POSITION")));
	check_bytes(view_bytes(&before,4),view_bytes(&first,attr_view(text,"NORMAL")));
	usz index = number(text,{{.key="meshes"},{.at=0},{.key="primitives"},{.at=0},{.key="indices"}});
	check_bytes(view_bytes(&before,3),view_bytes(&first,number(text,{{.key="accessors"},{.at=index},{.key="bufferView"}})));
	usz morph = number(text,{{.key="meshes"},{.at=0},{.key="primitives"},{.at=0},{.key="targets"},{.at=0},{.key="POSITION"}});
	check_bytes(view_bytes(&before,5),view_bytes(&first,number(text,{{.key="accessors"},{.at=morph},{.key="sparse"},{.key="indices"},{.key="bufferView"}})));
	check_bytes(view_bytes(&before,6),view_bytes(&first,number(text,{{.key="accessors"},{.at=morph},{.key="sparse"},{.key="values"},{.key="bufferView"}})));
	check_bytes(view_bytes(&before,7),view_bytes(&first,number(text,{{.key="images"},{.at=0},{.key="bufferView"}})));
	test::eq(gltf_edit::read_gltf_member(text,{{.key="extras"}}),gltf_edit::read_gltf_member((String)before.json,{{.key="extras"}}));
	test::eq(gltf_edit::read_gltf_member(text,{{.key="materials"}}),gltf_edit::read_gltf_member((String)before.json,{{.key="materials"}}));
	for (usz i=0;i<3;i++)
	{
		rewrite(path)!!;
		gltf_edit::GlbParts again = gltf_edit::split_glb(mem,path)!!;
		defer again.free(mem);
		test::eq(again.rest.len,first.rest.len);
		test::eq(again.json.len,first.json.len);
		test::eq(array_count((String)again.json,"accessors"),(usz)7);
		test::eq(array_count((String)again.json,"bufferViews"),(usz)9);
	}
	// Adding then removing animation must reclaim its sampler arrays and bytes.
	rewrite(path,true)!!;
	rewrite(path)!!;
	gltf_edit::GlbParts cleared = gltf_edit::split_glb(mem,path)!!;
	defer cleared.free(mem);
	test::eq(cleared.rest.len,first.rest.len);
	test::eq(array_count((String)cleared.json,"accessors"),(usz)7);
}

fn void shared_skin_data_is_retained_and_unknown_extensions_skip_cleanup() @test
{
	String path = "build/reskin-compaction-shared.glb";
	fixture(path);
	defer (void)file::delete(path);
	gltf_edit::GlbParts original = gltf_edit::split_glb(mem,path)!!;
	defer original.free(mem);
	String shared = gltf_edit::patch_raw(mem,(String)original.json,{{.key="skins"}},
		`[{"joints":[1],"skeleton":1,"inverseBindMatrices":6},{"joints":[1],"skeleton":1,"inverseBindMatrices":6}]`)!!;
	defer alloc::free(mem,shared.ptr);
	gltf_edit::GlbParts changed = original;
	changed.json = (char[])shared;
	gltf_edit::write_glb(path,changed)!!;
	rewrite(path)!!;
	gltf_edit::GlbParts result = gltf_edit::split_glb(mem,path)!!;
	defer result.free(mem);
	String text = (String)result.json;
	usz ibm = number(text,{{.key="skins"},{.at=1},{.key="inverseBindMatrices"}});
	usz view = number(text,{{.key="accessors"},{.at=ibm},{.key="bufferView"}});
	check_bytes(view_bytes(&original,8),view_bytes(&result,view));
	rewrite(path)!!;
	gltf_edit::GlbParts again = gltf_edit::split_glb(mem,path)!!;
	defer again.free(mem);
	test::eq(again.rest.len,result.rest.len);
	test::eq(again.json.len,result.json.len);

	// An unknown extension could reference any accessor/index/byte range. Keep
	// the original arrays and bytes rather than guess how to rewrite its schema.
	String extended = gltf_edit::patch_raw(mem,(String)original.json,{{.key="extensions"}},
		`{"CUSTOM_payload":{"accessor":1,"bufferView":2}}`)!!;
	defer alloc::free(mem,extended.ptr);
	changed.json = (char[])extended;
	gltf_edit::write_glb(path,changed)!!;
	rewrite(path)!!;
	gltf_edit::GlbParts kept = gltf_edit::split_glb(mem,path)!!;
	defer kept.free(mem);
	check_bytes(original.rest[8:312],kept.rest[8:312]);
	test::eq(array_count((String)kept.json,"accessors"),(usz)10);
	test::eq(gltf_edit::read_gltf_member((String)kept.json,{{.key="extensions"}}),
		gltf_edit::read_gltf_member(extended,{{.key="extensions"}}));
}

fn void humanoid_save_is_compact_and_size_stable() @test
{
	String source = "assets/animations/humanoid.glb";
	String path = "build/reskin-humanoid-compact.glb";
	char[] original = file::load(mem,source)!!;
	defer alloc::free(mem,original);
	file::save(path,original)!!;
	rig::TriMesh mesh = rig::load_gltf(mem,path)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh,path);
	defer app.free();
	test::@check(app.import_rig_from_source(),"the real humanoid rig must import");
	test::@check(app.write_rig_into_model(path),"the real humanoid rig must save");
	char[] compact = file::load(mem,path)!!;
	defer alloc::free(mem,compact);
	// A little slack for float reprinting (a rest offset of 0.025 can come back as
	// 0.024999999); accumulated skin payload is kilobytes, and the repeated saves
	// below must then match to the byte.
	test::@check(compact.len <= original.len + 256,"saving an existing rig must not accumulate skin payload");
	for (usz i=0;i<2;i++)
	{
		test::@check(app.write_rig_into_model(path),"a repeated save must succeed");
		char[] again = file::load(mem,path)!!;
		defer alloc::free(mem,again);
		test::eq(again.len,compact.len);
	}
	char[] untouched = file::load(mem,source)!!;
	defer alloc::free(mem,untouched);
	check_bytes(original,untouched);
}

<*
 Importing a rigged glb auto-binds every embedded clip that drives the new rig —
 the animations built for this mesh, bound so opening the file plays them at once.
 Since Save writes only bound clips, an import that left them unbound would drop
 them on the first save; auto-bind is what keeps them. One Ctrl+Z takes the rig
 and its bindings together.
*>
fn void import_auto_binds_the_files_own_clips() @test
{
	io::printn("importing a rigged glb auto-binds its embedded clips that drive the rig");
	String source = "assets/animations/humanoid.glb";
	String path = "build/import-autobind.glb";
	char[] original = file::load(mem, source)!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;
	defer (void)file::delete(path);

	// How many clips the file carries — every one drives the humanoid rig, so every
	// one must bind. Read here rather than hard-coded, so the assertion still holds
	// if the fixture's clip set changes.
	gltf::GltfStream stream = gltf::open(path, mem)!!;
	sz file_clips = stream.gltf.animations.len();
	test::@check(file_clips > 0, "the humanoid fixture should carry clips");
	String first = file_clips > 0 ? stream.gltf.animations[0].name.copy(mem) : "";
	defer if (file_clips > 0) first.free(mem);
	stream.close();

	rig::TriMesh mesh = rig::load_gltf(mem, path)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, path);
	defer app.free();

	test::eq((sz)app.doc.animations.len(), (sz)0);
	test::@check(app.import_rig_from_source(), "the real humanoid rig must import");

	test::eq((sz)app.doc.animations.len(), file_clips);
	sz walk = app.doc.bound_index(path, first);
	test::@check(walk >= 0, "%s was not auto-bound", first);
	test::@check(app.resolve_bound(walk).valid(), "the auto-bound clip does not resolve to a template");

	test::@check(app.undo(), "import did not undo");
	test::eq((sz)app.doc.animations.len(), (sz)0);
}

// The whole-index position of a Current file animation named `name`, or -1.
fn sz current_animation_index(crig::AppState* app, String name)
{
	foreach (usz i, &entry : app.assets.entries)
	{
		if (entry.kind == crig::AssetKind.ANIMATION && entry.current && entry.name == name)
		{
			return (sz)i;
		}
	}
	return -1;
}

// The name of some Current file animation, or "" if there are none.
fn String first_current_animation(crig::AppState* app)
{
	foreach (&entry : app.assets.entries)
	{
		if (entry.kind == crig::AssetKind.ANIMATION && entry.current) return entry.name;
	}
	return "";
}

<*
 A model opened from outside every configured library still lists its own clips:
 they are indexed as the "Current file" group — sentinel-library entries marked
 `current` — and the sidebar offers a row for them.
*>
fn void current_file_group_lists_the_model_animations() @test
{
	io::printn("the loaded model's own animations are indexed as the Current file group");
	String source = "assets/animations/humanoid.glb";
	String path = "build/current-file-group.glb";
	char[] original = file::load(mem, source)!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;
	defer (void)file::delete(path);
	defer (void)file::delete("build/current-file-group.rigsmith.json");

	gltf::GltfStream stream = gltf::open(path, mem)!!;
	sz file_clips = stream.gltf.animations.len();
	stream.close();
	test::@check(file_clips > 0, "the humanoid fixture should carry clips");

	rig::TriMesh mesh = rig::load_gltf(mem, path)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, path);
	defer app.free();
	// No configured libraries: the model is opened from outside every shelf, which is
	// exactly the case the sentinel indexing exists for.
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.reindex_current_model();

	sz current = 0;
	foreach (&entry : app.assets.entries)
	{
		if (entry.kind == crig::AssetKind.ANIMATION && entry.current)
		{
			current++;
			test::@check(entry.file == path, "a current entry names another file");
			test::eq(entry.library, crig::CURRENT_MODEL_LIBRARY);
		}
	}
	test::eq(current, file_clips);

	// The sidebar offers a "Current file" row counting exactly those clips.
	bool has_row = false;
	crig::AssetCategory current_cat = {};
	foreach (cat : app.asset_categories)
	{
		if (cat.current_file) { has_row = true; current_cat = cat; }
	}
	test::@check(has_row, "no Current file category was offered");
	test::eq((sz)current_cat.count, file_clips);
}

<*
 Deleting a Current file animation un-binds it and re-saves the model in place, so
 the clip is gone from the glb on disk — the asset-view delete end to end.
*>
// A material extension names textures, never an accessor or a view, so a file
// using one still compacts — a Tripo export (KHR_materials_specular, …) grew by a
// whole skin and every old clip on each save before this.
fn void material_extensions_do_not_stop_cleanup() @test
{
	String path = "build/reskin-compaction-material-ext.glb";
	fixture(path);
	defer (void)file::delete(path);
	gltf_edit::GlbParts original = gltf_edit::split_glb(mem,path)!!;
	defer original.free(mem);
	String used = gltf_edit::patch_raw(mem,(String)original.json,{{.key="extensionsUsed"}},
		`["KHR_materials_specular","FB_ngon_encoding"]`)!!;
	defer alloc::free(mem,used.ptr);
	String extended = gltf_edit::patch_raw(mem,used,{{.key="materials"}},
		`[{"name":"skin","extensions":{"KHR_materials_specular":{"specularFactor":0.5}}}]`)!!;
	defer alloc::free(mem,extended.ptr);
	gltf_edit::GlbParts changed = original;
	changed.json = (char[])extended;
	gltf_edit::write_glb(path,changed)!!;

	rewrite(path,true)!!;
	rewrite(path)!!;
	gltf_edit::GlbParts first = gltf_edit::split_glb(mem,path)!!;
	defer first.free(mem);
	test::eq(array_count((String)first.json,"accessors"),(usz)7);
	rewrite(path)!!;
	gltf_edit::GlbParts again = gltf_edit::split_glb(mem,path)!!;
	defer again.free(mem);
	test::eq(again.rest.len,first.rest.len);
	test::@check(((String)again.json).contains("KHR_materials_specular"), "the material lost its extension");
}

fn void delete_model_animation_removes_it_from_the_file() @test
{
	io::printn("deleting a Current file animation re-saves the model without it");
	String source = "assets/animations/humanoid.glb";
	String path = "build/delete-model-anim.glb";
	char[] original = file::load(mem, source)!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;
	defer (void)file::delete(path);
	defer (void)file::delete("build/delete-model-anim.rigsmith.json");

	rig::TriMesh mesh = rig::load_gltf(mem, path)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, path);
	defer app.free();
	// Write over this file rather than a copy aside — the point of the test is the
	// file the delete acts on.
	app.saves_in_place = true;
	sz file_clips = file_count(path);
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.reindex_current_model();

	// Delete "Fall" if the fixture still carries it, else whatever clip is first.
	String victim = "Fall";
	sz which = current_animation_index(&app, victim);
	if (which < 0)
	{
		victim = first_current_animation(&app);
		which = current_animation_index(&app, victim);
	}
	test::@check(which >= 0, "the Current file group should list a clip to delete");
	test::@check(app.doc.bound_index(path, victim) >= 0, "the clip should be auto-bound");

	test::@check(app.delete_model_animation((usz)which), "delete refused");

	// Gone from the binding and from the file on disk; other clips survive.
	test::eq(app.doc.bound_index(path, victim), (sz)-1);
	gltf::GltfStream after = gltf::open(path, mem)!!;
	sz remaining = after.gltf.animations.len();
	bool still_there = false;
	foreach (anim : after.gltf.animations) if (anim.name == victim) still_there = true;
	after.close();
	test::@check(!still_there, "the clip survived the delete in the file");
	// Exactly the one clip left: the re-save keeps every other bound clip.
	test::eq(remaining, file_clips - 1);
	// With no clip left their settings go too, rather than riding on in extras.
	if (remaining == 0)
	{
		gltf_edit::GlbParts parts = gltf_edit::split_glb(mem,path)!!;
		defer parts.free(mem);
		test::eq(gltf_edit::read_gltf_member((String)parts.json,{{.key="extras"},{.key="clips"}}), "");
	}
}

// The number of animations a glb on disk carries.
fn sz file_count(String path)
{
	gltf::GltfStream stream = gltf::open(path, mem)!!;
	defer stream.close();
	return stream.gltf.animations.len();
}


<*
 A save in place carries the rig's limits into the model, as the export does,
 and takes them back out when the rig has none.

 The shipped humanoid opened with its sidecar has a table on fifty-one joints.
 After a save the .glb reads back as a pack with the same fifty-one rows, each
 with the frame the editor derives — automatic on a chain, the named child at a
 fork — and a second save neither grows the file nor renumbers it. Tables taken
 off leave a file with no physics extension declared and no provenance, so a
 reader does not find joints indexing a list that is gone; one table put back
 is one row again.
*>
fn void humanoid_save_carries_its_limits_and_takes_them_back() @test
{
	String source = "assets/animations/humanoid.glb";
	String path = "build/reskin-humanoid-limits.glb";
	String sidecar = "build/reskin-humanoid-limits.rigsmith.json";
	char[] original = file::load(mem,source)!!;
	defer alloc::free(mem,original);
	file::save(path,original)!!;
	defer (void)file::delete(path);
	String source_sidecar = crig::session_path(mem, source);
	defer source_sidecar.free(mem);
	char[] session = file::load(mem,source_sidecar)!!;
	defer alloc::free(mem,session);
	file::save(sidecar,session)!!;
	defer (void)file::delete(sidecar);

	rig::TriMesh mesh = rig::load_gltf(mem,path)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh,path);
	defer app.free();
	app.adopt_source_rig();
	test::eq(app.doc.rotation_limits.len(),(sz)51);

	test::@check(app.write_rig_into_model(path),"the humanoid must save with its limits");
	char[] saved = file::load(mem,path)!!;
	defer alloc::free(mem,saved);
	{
		crig::AnimPack pack = crig::read_pack(mem,path)!!;
		defer pack.free(mem);
		RigView view = app.open_rig(mem)!!;
		defer view.free(mem);
		usz exact = 0;
		foreach (usz j, row : pack.constraints.joints)
		{
			if (row.status != EXACT) continue;
			exact++;
			// The pack's joints are the file's nodes in the order the reader walks
			// them; match by name back to the document's table.
			crig::Dot* dot = app.dot_named(pack.joint_names[j]);
			test::@check(dot != null,"the saved file names a joint the rig has not: %s",pack.joint_names[j]);
			if (!dot) continue;
			crig::JointRotationLimits table = app.doc.rotation_limits_of(dot.id);
			test::@check(table.constrained,"%s reads back limited and is not",pack.joint_names[j]);
			for (usz a = 0; a < 3; a++)
			{
				test::@check(table.axes[a].same(row.axes[a]),"%s axis %d changed on the way through the file",pack.joint_names[j],a);
			}
			bool fork = pack.joint_names[j] == "chest" || pack.joint_names[j].starts_with("wrist");
			test::@check(row.frame_intent == (fork ? PRIMARY_CHILD : AUTOMATIC),
				"%s came back with a frame the editor would not derive",pack.joint_names[j]);
		}
		test::eq(exact,(usz)51);
		usz foreign = pack.constraints.foreign.len;
		test::eq(foreign,(usz)0);
	}

	test::@check(app.write_rig_into_model(path),"a second save must succeed");
	char[] again = file::load(mem,path)!!;
	defer alloc::free(mem,again);
	test::eq(again.len,saved.len);

	// The saved model alone, with no document beside it, is enough to bring
	// the limits back: opening it imports the rig it carries, tables included.
	{
		String alone = "build/reskin-humanoid-limits-alone.glb";
		file::save(alone,again)!!;
		defer (void)file::delete(alone);
		rig::TriMesh bare = rig::load_gltf(mem,alone)!!;
		defer bare.free(mem);
		crig::AppState reopened = crig::new_app(bare,alone);
		defer reopened.free();
		reopened.adopt_source_rig();
		test::eq(reopened.doc.rotation_limits.len(),(sz)51);
		test::@check(reopened.notice().contains("51 joint limits"),"the import did not say it brought the limits: %s",reopened.notice());
		test::@check(reopened.undo(),"the import left nothing to undo");
		test::eq(reopened.doc.rotation_limits.len(),(sz)0);
	}

	// Taken off: no rows, no declaration, no provenance.
	app.doc.rotation_limits.clear();
	test::@check(app.write_rig_into_model(path),"a save without limits must succeed");
	{
		crig::AnimPack pack = crig::read_pack(mem,path)!!;
		defer pack.free(mem);
		usz exact = 0;
		foreach (row : pack.constraints.joints) if (row.status == EXACT) exact++;
		test::eq(exact,(usz)0);
		gltf_edit::GlbParts parts = gltf_edit::split_glb(mem,path)!!;
		defer parts.free(mem);
		String text = (String)parts.json;
		test::@check(gltf_edit::read_gltf_member(text,{{.key="extensionsUsed"}}).len == 0,"the extension is still declared with nothing using it");
		test::@check(gltf_edit::read_gltf_member(text,{{.key="extensions"}}).len == 0,"the root extension object survived its last joint");
		test::@check(gltf_edit::read_gltf_member(text,{{.key="extras"},{.key="constraintFrames"}}).len == 0,"the provenance outlived its rows");
		test::@check(!text.contains(`"KHR_physics_rigid_bodies"`),"a node kept a physics entry indexing a list that is gone");
	}

	// One put back is one row.
	crig::Dot* knee = app.dot_named("knee_L");
	crig::JointRotationLimits limits = crig::unconstrained_rotation(knee.id);
	limits.constrained = true;
	limits.axes[0] = { .allowed = true, .minimum = 0.0f, .maximum = 2.0f };
	limits.axes[1] = { .allowed = false };
	limits.axes[2] = { .allowed = false };
	test::@check(app.doc.set_rotation_limits(knee.id,limits),"the knee would not take a table");
	test::@check(app.write_rig_into_model(path),"a save with one limit must succeed");
	{
		crig::AnimPack pack = crig::read_pack(mem,path)!!;
		defer pack.free(mem);
		usz exact = 0;
		foreach (usz j, row : pack.constraints.joints)
		{
			if (row.status != EXACT) continue;
			exact++;
			test::eq(pack.joint_names[j],"knee_L");
			test::@check(math::abs(row.axes[0].maximum - 2.0f) < 1.0e-6f && !row.axes[1].allowed,"the knee's row changed on the way through the file");
		}
		test::eq(exact,(usz)1);
	}
}

fn void malformed_live_references_refuse_without_changing_the_file() @test
{
	String path = "build/reskin-compaction-invalid.glb";
	fixture(path);
	defer (void)file::delete(path);
	gltf_edit::GlbParts original = gltf_edit::split_glb(mem,path)!!;
	defer original.free(mem);
	gltf_edit::JsonStep[5] index_path = {{.key="meshes"},{.at=0},{.key="primitives"},{.at=0},{.key="indices"}};
	gltf_edit::JsonStep[5] sparse_path = {{.key="accessors"},{.at=5},{.key="sparse"},{.key="values"},{.key="bufferView"}};
	foreach (which : (uint[]){0,1})
	{
		String invalid = gltf_edit::patch_raw(mem,(String)original.json,which == 0 ? index_path[..] : sparse_path[..],"999")!!;
		defer alloc::free(mem,invalid.ptr);
		gltf_edit::GlbParts changed = original;
		changed.json = (char[])invalid;
		gltf_edit::write_glb(path,changed)!!;
		char[] before = file::load(mem,path)!!;
		defer alloc::free(mem,before);
		bool refused = false;
		if (catch rewrite(path)) refused = true;
		test::@check(refused,"malformed live indices must not be silently pruned");
		char[] after = file::load(mem,path)!!;
		defer alloc::free(mem,after);
		check_bytes(before,after);
	}
}

// ---------------------------------------------------------------------------
// A mesh placed by a node transform, given a skin
//
// A character exported with a rotation or an offset on its object node arrives
// with its vertices in the node's local space and the placement in the node.
// glTF ignores a *skinned* node's transform, so crig folds that placement into
// the skin's bind matrix (see gltf_edit::Reskin.bind and AppState.write_rig_into_model)
// rather than refusing the save — and the mesh has to come back out exactly where
// the node put it.

// One unskinned node carrying a mesh, turned 90 degrees about Y and moved +10 in
// x. Positions are the file's own local space; the node transform is what places
// them in the world.
const String PLACED_JSON = `{
 "asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
 "nodes":[{"name":"placed","mesh":0,"translation":[10,0,0],"rotation":[0,0.70710677,0,0.70710677]}],
 "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
 "accessors":[
 {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,1]},
 {"bufferView":1,"componentType":5125,"count":3,"type":"SCALAR"}],
 "bufferViews":[
 {"buffer":0,"byteOffset":0,"byteLength":36},
 {"buffer":0,"byteOffset":36,"byteLength":12}],
 "buffers":[{"byteLength":48}]
}`;

fn void placed_fixture(String path)
{
	char[] rest = alloc::new_array(mem, char, 56);
	defer alloc::free(mem, rest);
	put_u32(rest, 0, 48);
	put_u32(rest, 4, 0x004e4942);
	// Local triangle: (1,0,0), (0,0,1), (0,1,0).
	float[9] positions = {1,0,0, 0,0,1, 0,1,0};
	for (usz i = 0; i < positions.len; i++) put_u32(rest, 8 + i*4, bitcast(positions[i], uint));
	uint[3] indices = {0,1,2};
	for (usz i = 0; i < 3; i++) put_u32(rest, 8 + 36 + i*4, indices[i]);
	gltf_edit::write_glb(path, { .json = (char[])PLACED_JSON, .rest = rest, .version = 2, .binary = true })!!;
}

fn Vec3 placed_point(Matrix4f m, Vec3 p)
{
	float[<4>] moved = m.apply({ p.x, p.y, p.z, 1.0f });
	return { moved.x, moved.y, moved.z };
}

fn void a_node_transform_folds_into_the_bind_and_the_mesh_holds_still() @test
{
	String path = "build/reskin-placed.glb";
	placed_fixture(path);
	defer (void)file::delete(path);

	// The file's local triangle, and where 90 degrees about Y then +10 in x puts
	// it: (x,y,z) -> (z, y, -x) + (10,0,0).
	Vec3[3] local = {{1,0,0},{0,0,1},{0,1,0}};
	Vec3[3] world = {{10,0,-1},{11,0,0},{10,1,0}};

	// What crig reads before it writes: the mesh is not upright, and the single
	// node transform above it is recoverable as one placement matrix that puts the
	// local vertices exactly on their world positions.
	gltf::GltfStream stream = gltf::open(path, mem)!!;
	rig::MeshParts parts = rig::mesh_parts(mem, &stream)!!;
	test::@check(!parts.upright(), "a mesh under a node transform reads as not upright");
	Matrix4f placement;
	test::@check(parts.shared_placement(&placement), "one node transform is one placement");
	foreach (usz i, at : local)
	{
		Vec3 put = placed_point(placement, at);
		test::@check((put - world[i]).length() < 1e-4f,
			"placement put vertex %d at (%.3f,%.3f,%.3f), not the world (%.3f,%.3f,%.3f)",
			i, put.x, put.y, put.z, world[i].x, world[i].y, world[i].z);
	}
	parts.free(mem);
	stream.close();

	// Write a one-joint skin with that placement folded into the bind, the way
	// AppState.write_rig_into_model now does for a model that has no skin of its
	// own. The joint's position is measured in the placed (world) space, as crig's
	// baked geometry is.
	gltf_edit::ReskinJoint[1] joints = {{ .name = "root", .parent = -1, .position = {10,0,0} }};
	gltf_edit::ReskinPart[1] written = {{ .node = 0, .mesh = 0, .primitive = 0, .base = 0, .count = 3 }};
	float[3] weights = {1,1,1};
	gltf_edit::reskin_glb(mem, path, {
		.joints = joints[..], .parts = written[..], .weights = weights[..],
		.vertices = 3, .skin = -1, .influences = 4, .bind = placement,
	})!!;

	// Reopen. The bind the file now carries has to read back as the one folded in,
	// so a second save stays stable; and with one joint at weight one the rest skin
	// is exactly that bind applied to the local vertex — which has to be the world
	// position the node used to put it at.
	gltf::GltfStream after = gltf::open(path, mem)!!;
	defer after.close();
	after.load_all_buffers()!!;
	rig::MeshParts skinned = rig::mesh_parts(mem, &after)!!;
	defer skinned.free(mem);
	test::@check(skinned.skin >= 0, "the model now carries a skin");
	test::@check(skinned.upright(), "a skinned part reads as upright — its node transform is ignored now");

	Matrix4f bind_back = rig::skin_bind_matrix(&after, skinned.skin);
	for (usz i = 0; i < 16; i++)
	{
		test::@check(math::abs(bind_back.m[i] - placement.m[i]) < 1e-4f,
			"the bind read back differs at %d: %.5f vs %.5f", i, bind_back.m[i], placement.m[i]);
	}
	foreach (usz i, at : local)
	{
		Vec3 rest = placed_point(bind_back, at);
		test::@check((rest - world[i]).length() < 1e-4f,
			"reskinned vertex %d rests at (%.3f,%.3f,%.3f), not the world (%.3f,%.3f,%.3f)",
			i, rest.x, rest.y, rest.z, world[i].x, world[i].y, world[i].z);
	}
}
