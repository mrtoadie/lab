/*
  NixOS config apps > Audio

  Edit: 10.08.2025
*/

{ pkgs, ... }:

{
    config = {
      environment.systemPackages = with pkgs; [
        audacity
        quodlibet
        reaper
      ];
    };
}