{ lib, stdenv, fetchFromGitLab, dpkg, gawk, perl, wget, coreutils, util-linux
, gnugrep, gnupg1, gnutar, gnused, gzip, makeWrapper }:
# USAGE like this: debootstrap sid /tmp/target-chroot-directory
# There is also cdebootstrap now. Is that easier to maintain?
let binPath = lib.makeBinPath [
    coreutils
    dpkg
    gawk
    gnugrep
    gnupg1
    gnused
    gnutar
    gzip
    perl
    wget
  ];
in stdenv.mkDerivation rec {
  pname = "debootstrap";
  version = "1.0.127";

  src = fetchFromGitLab {
    domain = "salsa.debian.org";
    owner = "installer-team";
    repo = pname;
    rev = version;
    sha256 = "sha256-KKH9F0e4HEO2FFh1/V5UIY5C95ZOUm4nUhVUGqpZWaI=";
  };

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall

    d=$out/share/debootstrap
    mkdir -p $out/{share/debootstrap,bin}

    substitute debootstrap $out/share/debootstrap/debootstrap \
      --subst-var-by VERSION ${version}

    substituteInPlace debootstrap \
      --replace 'CHROOT_CMD="chroot '  'CHROOT_CMD="${coreutils}/bin/chroot ' \
      --replace 'CHROOT_CMD="unshare ' 'CHROOT_CMD="${util-linux}/bin/unshare ' \
      --replace /usr/bin/dpkg ${dpkg}/bin/dpkg \
      --replace '#!/bin/sh' '#!/bin/bash' \
      --replace 'cp "$0"' "cp $out/share/debootstrap/debootstrap" \
      --subst-var-by VERSION ${version}

    mv debootstrap $out/bin

    cp -r . $d

    wrapProgram $out/bin/debootstrap \
      --set PATH ${binPath} \
      --set-default DEBOOTSTRAP_DIR $d

    mkdir -p $out/man/man8
    mv debootstrap.8 $out/man/man8

    rm -rf $d/debian

    patchShebangs $out/bin

    runHook postInstall
  '';

  meta = with lib; {
    description = "Tool to create a Debian system in a chroot";
    homepage = "https://wiki.debian.org/Debootstrap";
    license = licenses.mit;
    maintainers = with maintainers; [ marcweber ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
