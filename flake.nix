{
  description = "hs-bindgen-playground — paste a C header, get Haskell bindings";

  inputs = {
    # Pinned via flake.lock (bump with `nix flake update hs-bindgen`), not tracking main.
    hs-bindgen.url = "github:well-typed/hs-bindgen";
    # Same nixpkgs as hs-bindgen → no version skew, single eval.
    nixpkgs.follows = "hs-bindgen/nixpkgs";
    # Declarative disk layout for the nixos-anywhere Hetzner target.
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, hs-bindgen, disko }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      pkgsFor = system: import nixpkgs { inherit system; };
      cliFor = system: hs-bindgen.packages.${system}.hs-bindgen-cli;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.callPackage ./nix/package.nix {
            hsBindgenCli = cliFor system;
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          hsPkgs = pkgs.haskellPackages;
        in
        {
          default = pkgs.mkShell {
            # Runtime tools the server shells out to, plus the Haskell toolchain.
            packages = [
              (hsPkgs.ghcWithPackages (p: [
                p.scotty
                p.warp
                p.aeson
                p.wai
                p.wai-extra
                p.http-types
                p.temporary
              ]))
              hsPkgs.cabal-install
              hsPkgs.haskell-language-server
              pkgs.bubblewrap
              pkgs.coreutils
              pkgs.util-linux
              pkgs.llvmPackages_21.clang
              pkgs.doxygen
              (cliFor system)
            ];
          };
        }
      );

      nixosModules.default = import ./nix/module.nix self;

      # The integration test is a nixosTest (x86_64-linux; the deployment target).
      checks.x86_64-linux.integration =
        (pkgsFor "x86_64-linux").callPackage ./nix/test.nix {
          module = self.nixosModules.default;
        };

      # Example deployment host for nixos-anywhere; see nix/hetzner.nix.
      nixosConfigurations.hetzner = nixpkgs.lib.nixosSystem {
        modules = [
          { nixpkgs.hostPlatform = "x86_64-linux"; }
          disko.nixosModules.disko
          self.nixosModules.default
          ./nix/hetzner.nix
        ];
      };
    };
}
