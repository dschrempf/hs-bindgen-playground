{ lib
, haskellPackages
, makeWrapper
, stdenv
, bubblewrap
, coreutils
, util-linux
, llvmPackages_21
, doxygen
, hsBindgenCli
}:

let
  # The scotty server itself, built from this repo's cabal file.
  server = haskellPackages.callCabal2nix "hs-bindgen-playground" ../. { };

  # Everything the server shells out to at runtime, incl. inside the sandbox:
  #   bwrap/timeout/prlimit — spawn+confine the CLI;
  #   clang — version-matched binary the CLI needs to reparse macros;
  #   doxygen — documentation-comment generation.
  # The server forwards its own PATH into the bwrap sandbox, so all of these
  # must be here (they live in /nix/store, which the sandbox binds read-only).
  runtimeDeps = [
    hsBindgenCli
    bubblewrap
    coreutils
    util-linux
    llvmPackages_21.clang
    doxygen
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
