{
  lib,
  haskellPackages,
  makeWrapper,
  stdenv,
  bubblewrap,
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
  # The server forwards its PATH into the bwrap sandbox; the whole /nix/store is
  # bound read-only, so the CLI's clang/doxygen (part of its closure) are
  # reachable there too.
  runtimeDeps = [
    hsBindgenCli
    bubblewrap
    coreutils
    util-linux
  ];
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
      --set PLAYGROUND_STATIC_DIR ${../static} \
      --set PLAYGROUND_EXAMPLES_DIR ${../examples}
  '';

  passthru = { inherit server; };

  meta = {
    description = "Web playground for hs-bindgen";
    mainProgram = "hs-bindgen-playground";
  };
}
