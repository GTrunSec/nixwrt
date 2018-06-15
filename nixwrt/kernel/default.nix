{  stdenv
 , lzma
 , buildPackages
 , socFamily ? null
 , defaultConfig ? null
 , extraConfig ? {}
 , loadAddress ? "0x80000000"
 , entryPoint ? "0x80000000"
 , runCommand
 , writeText
 , dtsPath ? null
} :
let readConfig = file:
      let f = runCommand "defconfig.json"  { } ''
            echo -e "{\n" > $out
            (source ${file} ; for v in ''${!CONFIG@} ; do printf "  \"%s\": \"%s\",\n" "$v" "''${!v}" ;done ) >> $out
            echo -e "  \042SWALLOW_COMMA\042: \042n\042 \n}" >> $out
          '';
          attrset = builtins.fromJSON ( builtins.readFile f ); in
        lib.mapAttrs'
          (n: v: (lib.nameValuePair (lib.removePrefix "CONFIG_" n) v))
          attrset;
    ledeSrc = buildPackages.fetchFromGitHub {
      owner = "lede-project";
      repo = "source";
      rev = "57157618d4c25b3f08adf28bad5b24d26b3a368a";
      sha256 = "0jbkzrvalwxq7sjj58r23q3868nvs7rrhf8bd2zi399vhdkz7sfw";
    };
    configFiles = ["${ledeSrc}/target/linux/generic/config-4.9"
                   "${ledeSrc}/target/linux/${defaultConfig}"
                   ];
    configuration = let
      defaults = lib.foldl (a: b: a // b)
                           {}
                           (builtins.map readConfig configFiles);
      nixwrtConfig = { "TMPFS" = "y"; "DEVTMPFS" = "y"; };
      overridden = defaults // nixwrtConfig // extraConfig;
      in writeText "nixwrt_config"
        (builtins.concatStringsSep
          "\n"
          (lib.mapAttrsToList
            (name: value: "CONFIG_${name}=${value}")
            overridden));

    lib = stdenv.lib; in
stdenv.mkDerivation rec {
    name = "kernel";
    src = let
     url = {
       url = "https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-4.9.76.tar.xz";
       sha256 = "1pl7x1fnyhvwbdxgh0w5fka9dyysi74n8lj9fkgfmapz5hrr8axq";
     }; in buildPackages.fetchurl url;

    prePatch =  ''
      q_apply() {
        find $1 -type f | sort | xargs  -n1 patch -N -p1 -i
      }
      cp -dRv ${ledeSrc}/target/linux/generic/files/* .   # */
      cp -dRv ${ledeSrc}/target/linux/ramips/files-4.9/* .  # */
      cp -dRv ${ledeSrc}/target/linux/ar71xx/files/* .  # */
      q_apply ${ledeSrc}/target/linux/generic/backport-4.9/
      q_apply ${ledeSrc}/target/linux/generic/pending-4.9/
      q_apply ${ledeSrc}/target/linux/generic/hack-4.9/
      ${lib.optionalString (! isNull socFamily)
                           "q_apply ${ledeSrc}/target/linux/${socFamily}/patches-4.9/"}
      ${lib.optionalString (! isNull dtsPath)
                       "cp ${dtsPath} board.dts"
                       }
      chmod -R +w .
    '';

    patches = [ ./kernel-ath79-wdt-at-boot.patch
                ./kernel-lzma-command.patch
                ./kernel-memmap-param.patch
#                ./kernel-dts-enable-eth0.patch
                ];

    patchFlags = [ "-p1" ];

    hardeningDisable = ["all"];
    nativeBuildInputs = [buildPackages.pkgs.bc
     lzma buildPackages.stdenv.cc
     buildPackages.pkgs.ubootTools];
    CC = "${stdenv.cc.bintools.targetPrefix}gcc";
    HOSTCC = "gcc";
    CROSS_COMPILE = stdenv.cc.bintools.targetPrefix;
    ARCH = "mips";              # use "mips" here for both mips and mipsel
    dontStrip = true;
    dontPatchELF = true;

    configurePhase = ''
      substituteInPlace scripts/ld-version.sh --replace /usr/bin/awk ${buildPackages.pkgs.gawk}/bin/awk
      make V=1 mrproper
      cp ${configuration} .config
      make V=1 olddefconfig
    '';

    outputs = [ "dev" "out" "vmlinux"];
    buildPhase = ''
      make vmlinux
      objcopy -O binary -R .reginfo -R .notes -R .note -R .comment -R .mdebug -R .note.gnu.build-id -S vmlinux vmlinux.stripped
      if test -f board.dts; then
        cc -o scripts/patch-dtb ${ledeSrc}/tools/patch-image/src/patch-dtb.c
        cpp -nostdinc -x assembler-with-cpp -I${ledeSrc}/target/linux/ramips/dts -Iarch/mips/boot/dts -Iarch/mips/boot/dts/include -Iinclude/ -undef -D__DTS__  -o dtb.tmp board.dts
        scripts/dtc/dtc -O dtb -i${ledeSrc}/target/linux/ramips/dts/  -o vmlinux.dtb dtb.tmp
        scripts/patch-dtb vmlinux.stripped vmlinux.dtb
      fi
      rm -f vmlinux.stripped.lzma
      ${lzma}/bin/lzma -k -z vmlinux.stripped
      mkimage -A mips -O linux -T kernel -C lzma -a ${loadAddress} -e ${entryPoint} -n 'MIPS NixWrt Linux' -d vmlinux.stripped.lzma kernel.image
    '';

    installPhase = ''
      mkdir -p $out
      cp kernel.image $out/
      make headers_install INSTALL_HDR_PATH=$out
      cp vmlinux $vmlinux
    '';

    shellHook = ''
      export ledeSrc=${ledeSrc}
    '';
  }
