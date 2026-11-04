module crig_tests::mcp;
import crig;
import image;
import image::png;
import mcp;
import three;
import rig;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::collections::object;
import std::encoding::base64;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// The mesh: the same 2-unit cube as ui_test — the test is about dispatch,
// not geometry. Opened through `shared_app::open_cube`, which measures it once
// for the process at a grid coarse enough that a bind is not the slowest thing
// a check does.
