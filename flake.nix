{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;

    eachDefaultSystem = lib.genAttrs [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  in {
    packages = eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
    in {
      default = pkgs.stdenvNoCC.mkDerivation {
        pname = "deploy-sh";
        version = "0.2.0";
        nativeBuildInputs = [pkgs.makeWrapper];
        unpackPhase = "true";
        installPhase = ''
          install -DT ${./deploy.sh} $out/bin/deploy
        '';
        postFixup = ''
          wrapProgram $out/bin/deploy --set PATH ${with pkgs; lib.makeBinPath [coreutils bash gnugrep jq nixVersions.latest git openssh nix-diff nvd nix-output-monitor]}
        '';
      };
    });

    nixosModules.default = ./module.nix;
  };
}
