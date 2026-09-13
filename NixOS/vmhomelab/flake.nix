{
  description = "standalone k3s lab: 1 control-plane + 2 workers on NixOS/KVM";

  inputs.nixos-unstable.url = "github:NixOS/nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs }@inputs:
    let
      mkVm = { name, role ? "agent", ram ? "1024", extra ? {} }: {
        "${name}" = {
          networking.hostName = name;
          services.k3s = {
            enable = true;
            role = role;
            # standalone cluster: server is the only source of truth
            serverAddr = if role == "agent" then "https://192.168.122.50:6443" else null;
          };
        };
      };
    in
    {
      nixosConfigurations = {
        cp01 = nixos.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/shared.nix ./hosts/cp01.nix ];
        };
        worker01 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/shared.nix ./hosts/worker.nix ];
        };
        worker02 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/shared.nix ./hosts/worker.nix ];
        };
      };
    };
}
