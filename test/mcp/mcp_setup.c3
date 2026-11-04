<*
 The MCP protocol and the read-only tools, with no window, no GPU and no
 socket: raw JSON-RPC strings into `mcp::Server.handle_message`, parsed
 JSON back out.

 `c3c test --trust=full --test-filter crig_tests::mcp` — run from the crig
 directory, the pack library path is
 relative.

 Worth pinning, in the order an agent hits them:

 handshake    initialize echoes the protocol version and names the server
 catalog      tools/list names the five listed tools and nothing else, a hidden
              one is still dispatched, and resources answers the api docs
 docs         get_api_docs answers with an index, one section at a time, or one
              tool's own registration — which is where the arguments of a hidden
              tool are read
 eyes         get_scene / get_skeleton / get_pose parse and carry the rig
 hands        apply_clip lands a clip in a pack of its own, replaces one of
              the same name, survives a library reload, and turns the rig by
              the arithmetic the rotation asked for
 player       play starts a clip where the user would see it, from the time
              and with the looping asked for, and stop puts it back at rest
 keeping      save_pack writes the authored clips into the library as a file
              and reads them straight back off it, and refuses every write it
              cannot make safely
 eyes again   screenshot wraps a PNG as an image block a client can decode, and
              says so plainly when there is no window to photograph
 feedback     bad JSON, unknown methods, unknown tools and bad clip names
              come back as JSON-RPC errors, not crashes — and a refused clip
              says which value was refused and what would have been taken
*>
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
