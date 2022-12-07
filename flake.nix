{
  description = "Kernel Virtual Machine Testing Tools";

  inputs.flake-compat = {
    url = "github:edolstra/flake-compat";
    flake = false;
  };

  outputs = { self, nixpkgs, ... }:
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
            , zstd, python3Minimal, elfutils, gzip, kmod, vde2, llvmPackages
            , rustPlatform ? null, rustfmt ? null, rust-bindgen ? null, libiconv ? null
            , darwin ? null
            
            , use_clang ? stdenv.isDarwin
            , use_rust ? true }:

            stdenv.mkDerivation {
              pname = "ktest-host-tools";
              version =
                self.shortRev or "dirty-${toString self.lastModifiedDate}";

              src = self;

              buildInputs = [ bash libelf ncurses ];
              nativeBuildInputs = [ makeWrapper pkg-config ];

              dontPatchShebangs = true;

              installPhase = let
                default_bin = [ bash coreutils which gnugrep ] ++ lib.optional stdenv.isLinux util-linux;
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

                envVars = makeEnvVars ([ libelf ncurses openssl zstd ] ++ lib.optional use_rust libiconv);
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
                    makeKtestBinPath ([
                      qemu
                      socat
                      brotli
                      git
                      gnused
                      gawk
                      openssh
                      gdb
                    ] ++ lib.optional stdenv.isLinux iproute2
                    ++ (if use_clang then [ llvmPackages.lldb ] else [ gdb ]))
                  }

                cp build-test-kernel $out/lib/build-test-kernel
                makeWrapper $out/lib/build-test-kernel $out/bin/build-test-kernel \
                  --inherit-argv0 \
                  --set PATH ${
                    makeKtestBinPath ([
                      gnused
                      gawk
                      socat
                      brotli
                      
                      gnumake
                      bison
                      flex
                      findutils
                      bc
                      ncurses
                      pkg-config
                      diffutils
                      perl
                      python3Minimal
                      rsync
                      gzip
                      qemu
                      vde2
                      openssh
                      zstd
                    ] ++ (if use_clang then [ llvmPackages.clang llvmPackages.lld llvmPackages.bintools llvmPackages.llvm ] else [
                      gcc
                    ]) ++ lib.optionals stdenv.isLinux [ iproute2 kmod ]
                    ++ lib.optional stdenv.isDarwin darwin.cctools 
                    ++ lib.optionals use_rust [ rustPlatform.rust.rustc rustfmt rust-bindgen ])
                  } \
                  --set hardeningDisable all \
                  --prefix PKG_CONFIG_PATH ":" "${envVars.PKG}" \
                  --run "export NIX_LDFLAGS=\"${envVars.LD} \$NIX_LDFLAGS\"" \
                  --run "export NIX_CFLAGS_COMPILE=\"${envVars.C} \$NIX_CFLAGS_COMPILE\"" \
                  --set NIX_CC_WRAPPER_TARGET_HOST_${stdenv.cc.suffixSalt} 1 \
                  ${if use_clang then "--set KTEST_USE_CLANG 1" else ""} \
                  ${if use_rust then "--set RUST_LIB_SRC ${rustPlatform.rustLibSrc}" else ""}

                # Write runtime infos to nix-support
                # TODO: write support files
              '';
            }) {
            };
        };
      };
      overlays.default = self.overlays.ktest;

      packages = forAllSystems (system: {
        inherit (nixpkgsFor.${system}) ktest-host-tools debootstrap-foreign;
        default = self.packages.${system}.ktest-host-tools;
      });

    };
}