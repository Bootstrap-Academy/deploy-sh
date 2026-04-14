{ lib, pkgs, ... }:

{
  tree-root-file = "treefmt.nix";
  on-unmatched = "fatal";

  excludes = [
    "*.lock"
    "*.md"
    "LICENSE"
  ];

  formatter.nixfmt = {
    command = lib.getExe pkgs.nixfmt;
    includes = [ "*.nix" ];
    options = [ "--strict" ];
  };

  formatter.shfmt = {
    command = lib.getExe pkgs.shfmt;
    includes = [ "*.sh" ];
    options = [
      "--simplify"
      "--write"
      "--indent=2"
    ];
  };
}
