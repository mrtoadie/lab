{ config, pkgs, ... }: {
  # lean VM: no docs, no man pages, no sound
  documentation.enable = false;
  documentation.man.enable = false;
  sound.enable = false;

  # qemu guest agent + ssh (required by nixos-anywhere)
  services.qemuGuest.enable = true;
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "prohibit-password";

  users.users.root.initialPassword = "lab";   # change after first login!
  # better: add your ssh pubkey here
  # users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... toadie@arch" ];

  services.k3s.enable = true;

  environment.systemPackages = with pkgs; [ curl vim ];

  networking.firewall.allowedTCPPorts = [ 22 ];
  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";
}
