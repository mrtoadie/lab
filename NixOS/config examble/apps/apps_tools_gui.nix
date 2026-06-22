/*
  NixOS config apps > Tools GUI

  Edit: 10.08.2025
*/

{ pkgs, ... }:

{
    config = {
      environment.systemPackages = with pkgs; [
        /*
        Tools GUI
        */
        obsidian
      ];
    };
}