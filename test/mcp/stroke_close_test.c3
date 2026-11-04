module crig_tests::mcp;

import crig;
import std::core::test;

// The leak check is the assert: the mirror built for the stroke must go with the app.
fn void closing_mid_stroke_frees_its_mirror() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	f.app.select(named_dot(f, "knee_L"));
	f.app.begin_stroke();
	test::@check(f.app.stroke_twin != 0, "the stroke found no twin to mirror onto");
}
