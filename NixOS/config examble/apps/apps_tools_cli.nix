/*
  NixOS config apps > Tools CLI

  Edit: 10.08.2025
*/

{ pkgs, ... }:

{
    config = {
      environment.systemPackages = with pkgs; [
        /*
        Tools CLI
        */
        btop
        htop
        duf
        lsd
        mc
        /*
        Themeing
        */
        fastfetch
        starship
        /*
        Shell
        */
        zsh
        oh-my-zsh
      ];
    };
}
