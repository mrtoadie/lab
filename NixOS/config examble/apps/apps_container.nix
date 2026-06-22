/*
  NixOS config apps > Container

  Edit: 10.08.2025
*/

{ pkgs, ... }:

{
    config = {
      environment.systemPackages = with pkgs; [
        /*
        Container
        */
        docker
        docker-compose
        minikube
      ];
    };
}