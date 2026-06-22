/*
  NixOS config apps > Internet

  Edit: 10.08.2025
*/

{ pkgs, ... }:

{
    config = {
      environment.systemPackages = with pkgs; [
        /*
        Dev
        */
        brave
        filezilla
        thunderbird
      ];
    };
}