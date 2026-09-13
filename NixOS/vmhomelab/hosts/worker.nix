{ lib, ... }: {
  services.k3s.role = "agent";
  # join the standalone cp01 - IP is the NAT address of the cp VM
  services.k3s.serverAddr = "https://192.168.122.50:6443";
}
