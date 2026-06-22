/*
  NixOS config apps > VPN

  Edit: 10.08.2025
*/

{ pkgs, ... }:

{
    config = {
      environment.systemPackages = with pkgs; [
        backintime
        timeshift
      ];
    };
}