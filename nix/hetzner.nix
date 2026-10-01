# Hetzner Cloud host profile for `nixos-anywhere`, exported as
# `nixosModules.hetzner`. Host-specific values (root keys, static IPv6,
# `nixpkgs.hostPlatform`, `system.stateVersion`) belong to the importing
# configuration:
#   nixos-anywhere --flake <your-flake>#<host> root@<IP>
{ modulesPath, lib, config, ... }:

{
  imports = [
    # nixos-anywhere runs from the target's kexec/installer; this provides
    # sane defaults for a cloud VM without a scanned hardware-configuration.nix.
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # --- Disk layout (disko) -------------------------------------------------
  # Hetzner's x86 VMs boot via legacy BIOS, the Arm (CAX) ones via UEFI: the
  # hybrid layout boots under both. disko orders the EF02 partition first and
  # points GRUB's BIOS install at this disk.
  disko.devices.disk.main = {
    device = "/dev/sda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          type = "EF02";
          size = "1M";
        };
        ESP = {
          type = "EF00";
          size = "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  # --- Boot / base ---------------------------------------------------------
  boot.loader.grub = {
    efiSupport = true;
    # The removable path needs no EFI boot entry, which the BIOS boot of this
    # very install cannot register.
    efiInstallAsRemovable = true;
    # GRUB copies each kernel + initrd (~42M) to the 512M ESP above; the
    # default of 100 generations would fill it.
    configurationLimit = lib.mkDefault 10;
  };

  networking.hostName = lib.mkDefault "hs-bindgen-playground";
  # DHCP covers IPv4 only; Hetzner assigns IPv6 statically (gateway fe80::1),
  # so a host wanting IPv6 adds a systemd.network unit for it.
  networking.useNetworkd = true;
  networking.useDHCP = lib.mkDefault true;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  assertions = [
    {
      assertion = config.users.users.root.openssh.authorizedKeys.keys != [ ];
      message = "nixosModules.hetzner: set users.users.root.openssh.authorizedKeys.keys, or the installed host is unreachable.";
    }
  ];

  # --- The playground ------------------------------------------------------
  # Without a domain it is served as plain HTTP on port 80; setting `domain`
  # and `acmeEmail` turns on HTTPS via Let's Encrypt.
  services.hs-bindgen-playground.enable = true;
}
