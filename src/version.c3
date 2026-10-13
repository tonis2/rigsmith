<*
 The version this build reports, at the foot of the Help menu and on the first
 line of `--help`.

 A checkout says "dev". A release build is stamped from its v* tag before it
 compiles: `packaging/stamp-version.sh` rewrites the VERSION line, and the
 release workflow runs it. The stamped file is never committed.
*>
module crig;

const String VERSION = "dev";

const String VERSION_LABEL = "Rigsmith " +++ VERSION;
