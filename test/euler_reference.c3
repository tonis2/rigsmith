<*
 The limit angles as they were read before the swing-twist change: Euler angles
 of M = F^-1 * R * F, composed Rz * Ry * Rx, each row clamped on its own.

 Kept as a reference so the new reading can be held against the old one where the
 two must agree (a hinge, a shipped clip): the yardstick of the joint limits' tests.
 Not the shipped behaviour: `crig::joint_angles_from_rotation` is.
*>
module crig_tests::euler_reference;

import crig;
import std::math;
import std::math::quaternion;

fn Vec3 euler_angles(crig::JointLimitFrame frame, Quaternionf rotation)
{
	if (!frame.usable()) return {};
	Quaternionf basis = frame.rotation.normalize();
	return basis.invert().mul(rotation.normalize()).mul(basis).normalize().to_euler();
}

fn Quaternionf euler_rotation(crig::JointLimitFrame frame, Vec3 angles)
{
	if (!frame.usable()) return quaternion::IDENTITY;
	Quaternionf basis = frame.rotation.normalize();
	Quaternionf local = quaternion::from_euler{float}(angles.x, angles.y, angles.z);
	return basis.mul(local).mul(basis.invert()).normalize();
}

// The old clamp, verbatim: each Euler angle clamped linearly, a locked row set to its value.
fn Quaternionf euler_clamp(crig::JointLimitFrame frame, crig::JointRotationLimits limits, Quaternionf rotation)
{
	if (!limits.constrained || !frame.usable()) return rotation.normalize();
	Vec3 angles = euler_angles(frame, rotation);
	foreach (usz i, axis : limits.axes)
	{
		angles[i] = axis.allowed
			? math::clamp(angles[i], axis.minimum, axis.maximum)
			: axis.locked;
	}
	return euler_rotation(frame, angles);
}
