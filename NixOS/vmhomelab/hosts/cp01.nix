{ lib, ... }: {
  networking.hostName = "cp01";

  services.k3s.role = "server";
  services.k3s.extraFlags = toString [
    "--disable traefik"
    "--disable servicelb"
  ];

  # API + flannel ports reachable from the agents (same NAT net)
  networking.firewall.allowedTCPPorts = lib.mkForce [ 22 6443 ];
  networking.firewall.allowedUDPPorts = [ 8472 ];
}
