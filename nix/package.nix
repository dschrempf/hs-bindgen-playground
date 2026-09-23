{
  lib,
  haskellPackages,
  makeWrapper,
  stdenv,
  bubblewrap,
  closureInfo,
  coreutils,
  util-linux,
  hsBindgenCli,
}:

let
  # The scotty server itself, built from this repo's cabal file.
  server = haskellPackages.callCabal2nix "hs-bindgen-playground" ../. { };

  # Everything the server shells out to at runtime, incl. inside the sandbox:
  # bwrap/timeout/prlimit — spawn+confine the CLI. The CLI wrapper puts its own
  # version-matched clang and doxygen on PATH, so we no longer add them here.
  # The server forwards its PATH into the bwrap sandbox.
  runtimeDeps = [
    hsBindgenCli
    bubblewrap
    coreutils
    util-linux
  ];

  # The exact store paths the sandbox may read: the runtime closure of the tools
  # above, one per line. The server ro-binds these individually instead of all of
  # /nix/store, so a crafted `#include` can't read unrelated store paths (the
  # system closure, whatever a future module puts there) back out as
  # diagnostics. A runtime dep the closure misses makes the sandbox fail loudly.
  storePaths = "${closureInfo { rootPaths = runtimeDeps; }}/store-paths";
in
stdenv.mkDerivation {
  pname = "hs-bindgen-playground";
  inherit (server) version;

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    makeWrapper ${server}/bin/hs-bindgen-playground $out/bin/hs-bindgen-playground \
      --prefix PATH : ${lib.makeBinPath runtimeDeps} \
      --set PLAYGROUND_STORE_PATHS ${storePaths} \
      --set PLAYGROUND_STATIC_DIR ${../static} \
      --set PLAYGROUND_EXAMPLES_DIR ${../examples}
  '';

  passthru = { inherit server storePaths; };

  meta = {
    description = "Web playground for hs-bindgen";
    mainProgram = "hs-bindgen-playground";
  };
}
