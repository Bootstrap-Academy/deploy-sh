{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.deploy-sh;

  vars = {
    inherit (cfg)
      buildHost
      targetHost
      buildCache
      pushDerivations
      systemCopyStrategy
      ;
    systemDrv = config.system.build.toplevel.drvPath;
    system = config.system.build.toplevel.outPath;
    nomDrv = pkgs.nix-output-monitor.drvPath;
    nom = pkgs.nix-output-monitor.outPath;
    useSudo = if cfg.useSudo then "1" else "0";
  };
  text = lib.concatStringsSep "" (
    lib.mapAttrsToList (k: v: "local ${k}=${lib.escapeShellArg v}\n") vars
  );
in

{
  options.deploy-sh = {
    targetHost = lib.mkOption {
      type = lib.types.str;
      example = "root@10.13.37.2";
      description = ''
        The host to deploy the system on.
        Both the local host and the build host have to be able to connect to this host via SSH.
        If `systemCopyStrategy` is set to `via-local`, only the local host has to be able to connect.
      '';
    };

    buildHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      defaultText = lib.literalExpression "config.deploy-sh.targetHost";
      example = "root@10.13.37.3";
      description = ''
        The host to build the system on.
        The local host has to be able to connect to this host via SSH.
      '';
    };

    buildCache = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/cache/deploy-sh/HOSTNAME";
      description = ''
        A path on the build host where to store a symlink to the new system to avoid garbage collection.
      '';
    };

    useSudo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Whether to use sudo for commands that require privileges on the target host.
      '';
    };

    systemCopyStrategy = lib.mkOption {
      type = lib.types.enum [
        "direct"
        "via-local"
      ];
      default = "direct";
      example = "via-local";
      description = ''
        How to copy the new system from the build host to the target host.

        - `direct`: The build host connects directly to the target host via SSH.
        - `via-local`: The system is first copied to the local host and then from there to the target host. No direct connection between build host and target host is required for this.
      '';
    };

    enableDiff = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        Whether to enable diffs between old and new configurations using the `--diff` and `--nvd` options.
      '';
    };

    pushDerivations = lib.mkOption {
      type = lib.types.bool;
      defaultText = lib.literalExpression "config.deploy-sh.enableDiff";
      description = ''
        Whether to copy the system `*.drv` files to the target host.
        Required for diffs to work if `buildHost != targetHost`.
      '';
    };

    _config = lib.mkOption {
      visible = false;
      readOnly = true;
    };
  };

  config = {
    deploy-sh = {
      buildHost = lib.mkDefault cfg.targetHost;
      pushDerivations = lib.mkDefault cfg.enableDiff;
      _config = pkgs.writeText "deploy-sh-config" (builtins.unsafeDiscardStringContext text);
    };

    nix.settings.keep-derivations = lib.mkIf cfg.enableDiff true;
  };
}
