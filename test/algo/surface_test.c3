// The Textured view's reader: the uvs and material runs of a glTF, lined up with
// the merged mesh crig edits.
module crig_tests::surface;
import rig;
import gltf;
import std::core::test;

const String PAINTED = "assets/animations/humanoid.glb";
const String BARE = "assets/animations/quadruped.glb";

fn rig::Surface? surface_of(String path, rig::TriMesh* mesh) @local
{
	gltf::GltfStream stream = gltf::open(path, mem)!;
	defer stream.close();
	stream.load_all_buffers()!;
	*mesh = rig::from_gltf(mem, &stream)!;
	return rig::read_surface(mem, &stream);
}

<*
 Every merged vertex gets its uv and every merged triangle falls in exactly one
 material run, in the order the flattener laid them down — or the picture lands
 on the wrong parts.
*>
fn void a_surface_lines_up_with_the_merged_mesh() @test
{
	rig::TriMesh mesh;
	rig::Surface surface = surface_of(PAINTED, &mesh)!!;
	defer
	{
		surface.free(mem);
		mesh.free(mem);
	}

	test::@check(surface.fits(&mesh), "the surface does not line up with the mesh it was read beside");
	test::@check(surface.has_uvs, "the humanoid carries uvs");
	test::@check(surface.uvs.len == mesh.positions.len, "one uv per merged vertex");
	test::@check(surface.runs.len > 0, "the humanoid has no material runs");

	usz next = 0;
	foreach (run : surface.runs)
	{
		test::@check(run.index_start == next, "a run does not start where the last one ended");
		test::@check(run.material >= 0, "each humanoid primitive names its material");
		next += run.index_count;
	}
	test::@check(next == mesh.indices.len, "the runs do not cover the merged indices");

	usz placed = 0;
	foreach (uv : surface.uvs) if (uv.x != 0 || uv.y != 0) placed++;
	test::@check(placed * 2 > surface.uvs.len, "most uvs are zero: %d of %d placed", placed, surface.uvs.len);
}

<*
 A file without uvs still has runs to draw in its material colours, and says it
 has nothing to put a picture on.
*>
fn void a_surface_without_uvs_says_so() @test
{
	rig::TriMesh mesh;
	rig::Surface surface = surface_of(BARE, &mesh)!!;
	defer
	{
		surface.free(mem);
		mesh.free(mem);
	}
	test::@check(surface.fits(&mesh), "the surface does not line up with the mesh");
	test::@check(!surface.has_uvs, "no primitive carries TEXCOORD_0");
	foreach (uv : surface.uvs) test::@check(uv.x == 0 && uv.y == 0, "a missing uv is not zero");
}

<*
 A mesh that is not the one the file flattens to — a body built in crig, or one
 edited since — does not fit, so Textured falls back to Solid.
*>
fn void a_surface_does_not_fit_another_mesh() @test
{
	rig::TriMesh mesh;
	rig::Surface surface = surface_of(PAINTED, &mesh)!!;
	defer
	{
		surface.free(mem);
		mesh.free(mem);
	}
	rig::TriMesh other = { .positions = mesh.positions[:3], .indices = mesh.indices[:3] };
	test::@check(!surface.fits(&other), "a surface fitted a mesh it was not read beside");
}
