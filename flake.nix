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
            , gnugrep, findutils, wget, qemu, socat, brotli, git, gnused
            , iproute2, openssh, gdb, gcc, gnumake, bison, flex, bc, ncurses
            , pkg-config, diffutils, libelf, perl, nettools, openssl, rsync
            , zstd, python3Minimal, elfutils, gzip, kmod, vde2 }:

            stdenv.mkDerivation {
              pname = "ktest-host-tools";
              version =
                self.shortRev or "dirty-${toString self.lastModifiedDate}";

              src = self;

              buildInputs = [ bash libelf ncurses ];
              nativeBuildInputs = [ makeWrapper pkg-config ];

              dontPatchShebangs = true;

              installPhase = let
                default_bin = [ bash util-linux coreutils which gnugrep ];
                makeKtestBinPath = extraBin:
                  lib.makeBinPath (default_bin ++ extraBin);

                makeEnvVars = pkgs: {
                  PKG = lib.concatStringsSep ":"
                    (map (x: "${x.dev or x.out}/lib/pkgconfig") pkgs);
                  LD =
                    lib.concatStringsSep " " (map (x: "-L${x.out}/lib") pkgs);
                  C = lib.concatStringsSep " "
                    (map (x: "-isystem ${x.dev or x.out}/include") pkgs);
                };

                envVars = makeEnvVars [ elfutils libelf ncurses openssl zstd ];
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
                      findutils
                      wget
                    ]
                  } \
                  --set KTEST_DEBOOTSTRAP_SYSTEM 1

                cp ktest $out/lib/ktest
                makeWrapper $out/lib/ktest $out/bin/ktest \
                  --inherit-argv0 \
                  --set PATH ${
                    makeKtestBinPath [
                      qemu
                      socat
                      brotli
                      git
                      gnused
                      gawk
                      iproute2
                      openssh
                      gdb
                    ]
                  }

                cp build-test-kernel $out/lib/build-test-kernel
                makeWrapper $out/lib/build-test-kernel $out/bin/build-test-kernel \
                  --inherit-argv0 \
                  --set PATH ${
                    makeKtestBinPath [
                      gnused
                      gawk
                      socat
                      brotli
                      gcc
                      gnumake
                      bison
                      flex
                      bc
                      ncurses
                      pkg-config
                      diffutils
                      perl
                      python3Minimal
                      rsync
                      gzip
                      kmod
                      qemu
                      iproute2
                      vde2
                      openssh
                    ]
                  } \
                  --set hardeningDisable all \
                  --prefix PKG_CONFIG_PATH ":" "${envVars.PKG}" \
                  --run "export NIX_LDFLAGS=\"${envVars.LD} \$NIX_LDFLAGS\"" \
                  --run "export NIX_CFLAGS_COMPILE=\"${envVars.C} \$NIX_CFLAGS_COMPILE\"" \
                  --set NIX_CC_WRAPPER_TARGET_HOST_${stdenv.cc.suffixSalt} 1

                echo LD_FLAGS: $NIX_LDFLAGS
                echo NIX_CLFAGS_COMPILE $NIX_CFLAGS_COMPILE

                # Write runtime infos to nix-support
                # TODO: write support files
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
