# Example Hetzner Cloud host for `nixos-anywhere`. Rent any Cloud VM, then:
#   nixos-anywhere --flake .#hetzner root@<IP>
# Fill in the placeholders marked TODO before deploying.
{ modulesPath, lib, ... }:

{
  imports = [
    # nixos-anywhere runs from the target's kexec/installer; this provides
    # sane defaults for a cloud VM without a scanned hardware-configuration.nix.
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  # --- Disk layout (disko) -------------------------------------------------
  # Hetzner Cloud exposes the primary disk as /dev/sda and boots via UEFI.
  disko.devices.disk.main = {
    device = "/dev/sda";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
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
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  networking.hostName = "hs-bindgen-playground";
  networking.useDHCP = lib.mkDefault true;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  # TODO: your public key — nixos-anywhere needs root SSH access to install.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA... you@example" # TODO: replace
  ];

  # --- The playground ------------------------------------------------------
  services.hs-bindgen-playground = {
    enable = true;
    # TODO: once DNS points at the IP, set these to get HTTPS via Let's Encrypt.
    # Until then, the service is served as plain HTTP over the IP on port 80.
    domain = null; # e.g. "playground.example.com";
    acmeEmail = null; # e.g. "you@example.com";
  };

  system.stateVersion = "25.05";
}
