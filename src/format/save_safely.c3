<* Writing a file so that a failure can't leave half of one behind. *>
module crig;

import gltf_edit;

alias save_safely = gltf_edit::save_safely;
