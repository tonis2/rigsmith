<*
 The numbers every weight tool agrees on, in one place.

 Each of these used to live beside the one tool that first needed it, which is
 how the views came to count from a twentieth while the brush and the Area tool
 decided from a hundredth and the stray survey from a quarter — three answers to
 "does this joint hold this vertex" in one window. A tool that needs a threshold
 takes it from here, so two tools asked the same question give the same answer.
*>
module crig;

<*
 The share below which a joint's hold on a vertex is not worth reporting: what
 the views, `get_weights` and the readouts count from.

 Nothing the binder or the exporter applies — both keep whatever survives
 `sparsify_weights`, however small. It exists because a hold of a few percent is
 the binder's falloff rather than a statement about where the vertex belongs,
 and counting from zero would report every joint as reaching the whole mesh.
*>
const float SHOWN_FLOOR = 0.05f;

<*
 Below this share a joint's hold on a vertex outside its part is left alone by
 an Apply, and the brush's limb test counts it as no hold at all.

 Restating every row of the mesh to take a hundredth off it would pin the whole
 body.
*>
const float AREA_LEAK_FLOOR = 0.01;

<*
 The share of a vertex's automatic row its limb has to hold before the brush or
 an Apply may give the joint any of it — see `limb_family`.
*>
const float LIMB_FLOOR = 0.01;

<*
 How far behind a vertex's owner a joint may sit and still blend with it, as a
 share of the joint's own bone — the band the automatic weights end at (see
 `rig::window_bind`). Past it the joint holds nothing of the vertex.
*>
const float BAND_SHARE_DEFAULT = 0.5f;

// A joint holds a vertex, for the stray survey, at this share or more.
const float STRAY_SHARE = 0.25f;

<*
 A vertex whose joints together hold no more than this is unused: nothing
 moves it, so posed or exported it falls back to the root (`sparsify_weights`).

 A total rather than a share, because a share needs a total to divide by and
 this is the case where there is none. Nothing hands an unused vertex to anyone
 — the Unused view marks it so the user can.
*>
const float UNUSED_TOTAL = 1e-6f;
