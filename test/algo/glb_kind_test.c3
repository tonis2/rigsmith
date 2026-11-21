<*
 What an imported .glb is: a character, a level or a cutscene file, from its JSON alone.

     `c3c test --test-filter crig_tests::glb_kind`
*>
module crig_tests::glb_kind;

import crig;
import gltf_edit;
import std::collections::object;
import std::core::test;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;

const String FOLDER @local = "build/glb-kind-test";

// The rule on hand-written JSON, with what it counted.
fn GlbKind kind_of(String text, GlbCensus* census = null) @local
{
	Object* doc = json::parse(mem, text)!!;
	defer doc.free();
	return crig::glb_kind_of(doc, census);
}

fn void the_shipped_models_are_characters() @test
{
	foreach (model : (String[]){ "assets/animations/humanoid.glb", "assets/animations/quadruped.glb" })
	{
		GlbCensus census;
		GlbKind kind = crig::glb_kind(model, &census)!!;
		test::@check(kind == CHARACTER, "%s is a %s (%d loose colliders, %d armatures)", model, kind,
			census.loose_colliders, census.armatures);
	}
}

fn void the_cutscene_fixtures_are_cutscenes() @test
{
	String[] fixtures = {
		"assets/cutscenes/intro.cutscene.glb", "assets/cutscenes/finer.cutscene.glb", "assets/cutscenes/intro.cutscene.gltf",
		"assets/cutscenes/turn.cutscene.gltf",
	};
	foreach (fixture : fixtures)
	{
		test::@check((crig::glb_kind(fixture) ?? GlbKind.CHARACTER) == CUTSCENE, "%s is not read as a cutscene", fixture);
	}
}

fn void a_glb_s_json_chunk_is_read_alone() @test
{
	String model = "assets/animations/humanoid.glb";
	gltf_edit::GlbParts parts = gltf_edit::split_glb(mem, model)!!;
	defer parts.free(mem);
	char[] chunk = gltf_edit::glb_json_chunk(mem, model)!!;
	defer alloc::free(mem, chunk);
	test::@check(parts.binary && (String)chunk == (String)parts.json, "the chunk is the JSON split_glb finds");
	test::@check(chunk.len < (usz)file::get_size(model)!!, "and the buffer after it is not read");
}

fn void a_file_that_does_not_read_is_unreadable() @test
{
	test::@check(@catch(crig::glb_kind("build/glb-kind-test/nowhere.glb")) == crig::GLB_UNREADABLE, "a missing file");
	test::@check(@catch(crig::glb_kind("assets/cutscenes/intro.cutscene.bin")) == crig::GLB_UNREADABLE, "a bare buffer");
}

const String TWO_ARMATURES @local = `{
  "asset": { "version": "2.0" },
  "nodes": [
    { "name": "hero_rig", "children": [1, 2] },
    { "name": "hips" },
    { "name": "hero_body", "mesh": 0, "skin": 0 },
    { "name": "guide_rig", "children": [4, 5] },
    { "name": "root" },
    { "name": "guide_body", "mesh": 1, "skin": 1 }
  ],
  "skins": [ { "joints": [1] }, { "joints": [4] } ],
  "meshes": [ { "primitives": [] }, { "primitives": [] } ]
}`;

fn void two_rigged_armatures_are_a_level() @test
{
	(void)path::mkdir(FOLDER, true);
	String level = FOLDER +++ "/two_armatures.gltf";
	file::save(level, TWO_ARMATURES)!!;
	GlbCensus census;
	GlbKind kind = crig::glb_kind(level, &census)!!;
	test::@check(kind == LEVEL && census.armatures == 2 && census.loose_colliders == 0,
		"%s with %d armatures, %d loose colliders", kind, census.armatures, census.loose_colliders);
}

fn void one_armature_is_a_character() @test
{
	// Two skinned meshes under one armature, and one with no parent, which counts for nothing.
	String text = `{
	  "nodes": [
	    { "name": "rig", "children": [1, 2, 3] },
	    { "name": "hips" },
	    { "name": "body", "mesh": 0, "skin": 0 },
	    { "name": "cloak", "mesh": 1, "skin": 0 },
	    { "name": "loose", "mesh": 1, "skin": 0 }
	  ],
	  "skins": [ { "joints": [1] } ]
	}`;
	GlbCensus census;
	test::@check(kind_of(text, &census) == CHARACTER && census.armatures == 1, "%d armatures", census.armatures);

	// An unnamed armature is not counted, as `level_armatures` lists only named ones.
	String unnamed = `{
	  "nodes": [
	    { "children": [1] }, { "mesh": 0, "skin": 0 },
	    { "children": [3] }, { "mesh": 0, "skin": 0 }
	  ]
	}`;
	test::@check(kind_of(unnamed, &census) == CHARACTER && census.armatures == 0, "%d unnamed armatures", census.armatures);
}

fn void a_collider_on_a_plain_node_is_a_level() @test
{
	String text = `{
	  "nodes": [
	    { "name": "ground", "extensions": { "KHR_physics_rigid_bodies": { "collider": { "geometry": { "shape": 0 } } } } }
	  ]
	}`;
	GlbCensus census;
	test::@check(kind_of(text, &census) == LEVEL && census.loose_colliders == 1, "%d loose colliders", census.loose_colliders);

	String trigger = `{
	  "nodes": [
	    { "name": "door", "extensions": { "KHR_physics_rigid_bodies": { "trigger": { "geometry": { "shape": 0 } } } } }
	  ]
	}`;
	test::@check(kind_of(trigger, &census) == LEVEL && census.loose_colliders == 1, "a trigger: %d", census.loose_colliders);

	// A body with motion and nothing to collide with is not a collider.
	String moving = `{
	  "nodes": [ { "name": "leaf", "extensions": { "KHR_physics_rigid_bodies": { "motion": { "mass": 1 } } } } ]
	}`;
	test::@check(kind_of(moving, &census) == CHARACTER && census.loose_colliders == 0, "motion only: %d", census.loose_colliders);
}

fn void colliders_on_a_rig_are_a_character() @test
{
	// A sphere on a joint, and a capsule on a node under one, as Rigsmith writes them.
	String text = `{
	  "nodes": [
	    { "name": "rig", "children": [1, 4] },
	    { "name": "hips", "children": [2], "extensions": { "KHR_physics_rigid_bodies": { "collider": { "geometry": { "shape": 0 } } } } },
	    { "name": "spine", "children": [3] },
	    { "name": "spine_capsule", "extensions": { "KHR_physics_rigid_bodies": { "collider": { "geometry": { "shape": 1 } } } } },
	    { "name": "body", "mesh": 0, "skin": 0 }
	  ],
	  "skins": [ { "joints": [1, 2] } ]
	}`;
	GlbCensus census;
	GlbKind kind = kind_of(text, &census);
	test::@check(kind == CHARACTER && census.loose_colliders == 0 && census.armatures == 1,
		"%s with %d loose colliders", kind, census.loose_colliders);
}

fn void a_cutscene_extension_wins() @test
{
	String text = `{
	  "extensions": { "CUSTOM_cutscene": { "version": 2 } },
	  "nodes": [ { "name": "ground", "extensions": { "KHR_physics_rigid_bodies": { "collider": {} } } } ]
	}`;
	GlbCensus census;
	test::@check(kind_of(text, &census) == CUTSCENE && census.loose_colliders == 1, "a cutscene with a collider");
	test::@check(kind_of(`{"extensions": {"CUSTOM_cutscene": 3}}`) == CHARACTER, "an extension that is not an object");
}

fn void an_extension_is_matched_in_any_case() @test
{
	test::@check(crig::is_gltf_name("lib/Hero.Glb") && crig::is_gltf_name("a.GLTF") && !crig::is_gltf_name("glb"), "a glTF name");
}
