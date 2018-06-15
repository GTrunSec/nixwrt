# This is copy-pasted from backuphost.nix but will eventually be a
# configuration for a wireless access point based on Atheros 9331
# (testing on Arduino Yun, deploying on Trendnet TEW712BR)

{ targetBoard ? "yun" }:
let device = (import ./nixwrt/devices.nix).${targetBoard};
    modules = (import ./nixwrt/modules/default.nix);
    system = (import ./nixwrt/mksystem.nix) device;
    overlay = (import ./nixwrt/overlay.nix);
    nixpkgs = import <nixpkgs> (system // { overlays = [overlay] ;} ); in
with nixpkgs;
let
    rootfsImage = pkgs.callPackage ./nixwrt/rootfs-image.nix ;
    myKeys = (nixpkgs.stdenv.lib.splitString "\n" ( builtins.readFile "/etc/ssh/authorized_keys.d/dan" ) );
    busyboxArgs = { config, applets } :
      let xconfig = builtins.concatStringsSep "\n"
        (map (n: v: "CONFIG_${pkgs.lib.strings.toUpper n} ${v}") config);
          aconfig = builtins.concatStringsSep "\n"
        (map (n: "CONFIG_${pkgs.lib.strings.toUpper n} y") applets);
      in super.busybox.override {
        enableStatic = true;
        enableMinimal = true;
        extraConfig = ''
          ${xconfig}
          ${aconfig}
        '';
      };
in rec {
  testKernelAttrs = let k = (device.kernel lib); in {
    inherit lzma;
    dtsPath = if (k ? dts) then (k.dts nixpkgs) else null ;
    inherit (k) defaultConfig loadAddress entryPoint socFamily;
    extraConfig = k.extraConfig // {
      "9P_FS" = "y";
      "9P_FS_POSIX_ACL" = "y";
      "9P_FS_SECURITY" = "y";
      "ATH9K" = "y";
      "ATH9K_AHB" = "y";
      "BRIDGE_VLAN_FILTERING" = "y";
      "CFG80211" = "y";
      "EXT4_ENCRYPTION" = "y";
      "EXT4_FS" = "y";
      "EXT4_FS_ENCRYPTION" = "y";
      "EXT4_USE_FOR_EXT2" = "y";
      "MAC80211" = "y";
      "MSDOS_PARTITION" = "y"; "EFI_PARTITION" = "y";
      "NET_9P" = "y";
      "NET_9P_DEBUG" = "y";
      "NET_9P_VIRTIO" = "y";
      "PARTITION_ADVANCED" = "y";
      "PCI" = "y";
      "SCSI"  = "y"; "BLK_DEV_SD"  = "y"; "USB_PRINTER" = "y";
      "USB" = "y";
      "USB_ANNOUNCE_NEW_DEVICES" = "y";
      "USB_COMMON" = "y";
      "USB_EHCI_HCD" = "y";
      "USB_EHCI_HCD_PLATFORM" = "y";
      "USB_OHCI_HCD" = "y";
      "USB_OHCI_HCD_PLATFORM" = "y";
      "USB_STORAGE" = "y";
      "USB_STORAGE_DEBUG" = "n";
      "USB_UAS" = "y";
      "VIRTIO" = "y";
      "VIRTIO_NET" = "y";
      "VIRTIO_PCI" = "y";
      "WLAN_80211" = "y";
    };
  };

  kernel = pkgs.kernel.override testKernelAttrs;

  swconfig = pkgs.swconfig.override { inherit kernel; };

  rootfs = let baseConfiguration = rec {
      hostname = "uostairs";
      interfaces = {
        "eth1" = { };
        lo = { ipv4Address = "127.0.0.1/8"; };
        "wlan0" = { };
        "br0" = {
          type = "bridge";
          members  = [ "eth1" "wlan0" ];
        };
      };
      etc = {
        "resolv.conf" = { content = ( stdenv.lib.readFile "/etc/resolv.conf" );};
      };
      users = [
        {name="root"; uid=0; gid=0; gecos="Super User"; dir="/root";
         shell="/bin/sh"; authorizedKeys = myKeys;}
        {name="dan"; uid=1000; gid=1000; gecos="Daniel"; dir="/home/dan";
         shell="/bin/sh"; authorizedKeys = myKeys;}
      ];
      packages = [ swconfig pkgs.iprouteSansBash ];
      filesystems = { };
      services = {
      };
    };
    wantedModules = with modules; [
      (self: super: baseConfiguration)
      (sshd nixpkgs)
      (busybox nixpkgs)
#      (syslogd { loghost = "192.168.0.2"; } nixpkgs)
      (ntpd { host = "pool.ntp.org"; } nixpkgs)
      (hostapd {
        config = { interface = "wlan0"; ssid = "testlent"; hw_mode = "g"; channel = 1; };
        # no suport currently for generating these, use wpa_passphrase
        psk = builtins.getEnv "PSK";
      } nixpkgs)
      (dhcpClient { interface = "br0"; } nixpkgs)
    ];
    configuration = with nixpkgs.stdenv.lib; let extend = lhs: rhs: lhs // rhs lhs;
                    in lib.fix (self: lib.foldl extend {} (map (x: x self) wantedModules));
  in rootfsImage {
    inherit busybox configuration;
    inherit (pkgs) monit ;
    iproute = iprouteSansBash;
  };

  tftproot = stdenv.mkDerivation rec {
    name = "tftproot";
    phases = [ "installPhase" ];
    kernelImage = (if targetBoard == "malta" then kernel.vmlinux else "${kernel.out}/kernel.image");
    installPhase = ''
      mkdir -p $out
      cp ${kernelImage} $out/kernel.image
      cp ${rootfs}/image.squashfs  $out/rootfs.image
    '';
  };

  firmwareImage = stdenv.mkDerivation rec {
    name = "firmware.bin";
    phases = [ "installPhase" ];
    installPhase =
      let liveKernelAttrs = lib.attrsets.recursiveUpdate testKernelAttrs {
            extraConfig."CMDLINE" =
              builtins.toJSON "earlyprintk=serial,ttyS0 console=ttyS0,115200 panic=10 oops=panic init=/bin/init root=/dev/mtdblock5 rootfstype=squashfs";
          };
          kernel = pkgs.kernel.override liveKernelAttrs;
      in ''
        dd if=${kernel.out}/kernel.image of=$out bs=128k conv=sync
        dd if=${rootfs}/image.squashfs of=$out bs=128k conv=sync,nocreat,notrunc oflag=append
      '';
  };
}
