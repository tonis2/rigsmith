module crig_tests::ui;

import crig;
import std::core::test;
import std::math::vector;

enum SnapshotTint @local
{
	RED,
	BLUE,
}

struct SnapshotFields @local
{
	bool flag;
	uint count;
	float amount;
	Vec3 where;
	String name;
	char* source;
	SnapshotTint tint;
}

// Each change to one field is a difference, whatever the field's type.
fn void every_field_of_a_snapshot_counts() @test
{
	char[1] bytes;
	SnapshotFields base = { .name = "walk", .source = &bytes[0] };
	test::@check(!crig::fields_differ(base, base), "a snapshot differs from itself");

	SnapshotFields other = base;
	other.flag = true;
	test::@check(crig::fields_differ(base, other), "a bool");
	other = base;
	other.count = 1;
	test::@check(crig::fields_differ(base, other), "an integer");
	other = base;
	other.amount = 0.5f;
	test::@check(crig::fields_differ(base, other), "a float");
	other = base;
	other.where = { 0, 0, 1 };
	test::@check(crig::fields_differ(base, other), "one axis of a vector");
	other = base;
	other.name = "run";
	test::@check(crig::fields_differ(base, other), "a string");
	other = base;
	other.source = null;
	test::@check(crig::fields_differ(base, other), "a pointer");
	other = base;
	other.tint = BLUE;
	test::@check(crig::fields_differ(base, other), "an enum");
}

// The same text in other memory is no change, or a snapshot would rebuild each frame.
fn void a_string_is_compared_by_its_text() @test
{
	String copy = "walk".copy(mem);
	defer copy.free(mem);
	SnapshotFields a = { .name = "walk" };
	SnapshotFields b = { .name = copy };
	test::@check(!crig::fields_differ(a, b), "the same text counted as a change");
}
