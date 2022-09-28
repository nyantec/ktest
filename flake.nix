{
  description = "Kernel Virtual Machine Testing Tools";

  outputs = { self, nixpkgs }:
    let
      systems =
        [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      nixpkgsFor = forAllSystems (system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        });
    in {
      overlays = {
        ktest = final: prev: {
          debootstrap-foreign = final.callPackage ./nix/debootstrap { };

          ktest-host-tools = final.callPackage ({ stdenv, lib, bash, makeWrapper
            , util-linux, e2fsprogs, coreutils, which, debootstrap-foreign, gawk
            , gnugrep, findutils, wget }:

            stdenv.mkDerivation {
              pname = "ktest-host-tools";
              version =
                self.shortRev or "dirty-${toString self.lastModifiedDate}";

              src = self;

              buildInputs = [ bash ];
              nativeBuildInputs = [ makeWrapper ];

              installPhase =
                let
                  default_bin = [ bash util-linux coreutils which ];
                  makeKtestBinPath = extraBin: lib.makeBinPath (default_bin ++ extraBin);
                in ''
                  mkdir -p $out/bin $out/lib/lib

                  # Copy library files
                  cp -r lib $out/lib/

                  # Copy binary files and wrap
                  cp root_image $out/lib/root_image
                  makeWrapper $out/lib/root_image $out/bin/root_image \
                    --inherit-argv0 \
                    --set PATH ${
                      makeKtestBinPath [
                        e2fsprogs
                        debootstrap-foreign
                        gawk
                        gnugrep
                        findutils
                        wget
                      ]
                    } \
                    --set KTEST_DEBOOTSTRAP_SYSTEM 1
                '';
            }) { };
        };
      };
      overlays.default = self.overlays.ktest;

      packages = forAllSystems (system: {
        inherit (nixpkgsFor.${system}) ktest-host-tools debootstrap-foreign;
      });

      defaultPackage =
        forAllSystems (system: self.packages.${system}.ktest-host-tools);

    };
}
