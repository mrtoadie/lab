{ config, pkgs, ... }:
{
  config.programs.zsh = {
    enable = true;
    enableCompletion = false;
    histSize = 10000;
    ohMyZsh = 
      let
        zsh-autocomplete-src = pkgs.fetchFromGitHub {
          owner = "marlonrichert";
          repo = "zsh-autocomplete";
          rev = "25.03.19";
          sha256 = "sha256-eb5a5WMQi8arZRZDt4aX1IV+ik6Iee3OxNMCiMnjIx4=";
        };
        # remove run-tests.zsh
        sh-autocomplete = pkgs.runCommand "zsh-autocomplete-plugin" {} ''
          mkdir -p $out
          cp -r ${zsh-autocomplete-src}/. $out
          rm $out/run-tests.zsh
          '';
      in
      {
        enable = true;  
        theme = "robbyrussell";
        custom = "${zsh-autocomplete}";
      };
    shellAliases = { };
  };
}