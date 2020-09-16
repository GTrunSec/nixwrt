{ overlays ? []
, endian }:
let
  overlay = import ./overlay.nix;
  modules = import ./modules/default.nix;
  system = (import ./mksystem.nix) { inherit endian; };
  nixpkgs = import <nixpkgs> (system // { overlays = [overlay] ++ overlays;} );
in
with nixpkgs; rec {
  inherit  modules system nixpkgs;

  mergeModules = ms:
    let extend = lhs: rhs: lhs // rhs lhs;
    in lib.fix (self: lib.foldl extend {}
                  (map (x: x self) (map (f: f nixpkgs) ms)));

  monitrc = pkgs.callPackage ./monitrc.nix;

  rootfs = configuration: pkgs.callPackage ./rootfs-image.nix {
    busybox = configuration.busybox.package;
    monitrc = (monitrc configuration);
    inherit configuration;
  };
  kernel = configuration : configuration.kernel.package;
  firmware = configuration:
    pkgs.callPackage ./firmware.nix {
      kernelImage = configuration.kernel.package;
      rootImage = rootfs configuration;
    };
}
