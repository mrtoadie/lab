/*
  NixOS config apps > Dev

  Edit: 10.08.2025
*/

{ pkgs, ... }:

{
    config = {
      environment.systemPackages = with pkgs; [
        /*
        Dev
        */
        ansible
        git
        vscode
      ];
    };
}