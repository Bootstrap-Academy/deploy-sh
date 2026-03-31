# deploy-sh
Simple NixOS remote deployment tool

## Flake Setup
<details>
  <summary>
    <b>1.</b> Add a <code>deploy-sh.hosts</code> output to your <code>flake.nix</code>. This has to be an attribute set of NixOS systems.
  </summary>

  ```nix
  {
    outputs = {self, nixpkgs, ...}: {
      nixosConfigurations = {
        foo = nixpkgs.lib.nixosSystem { ... };
        bar = nixpkgs.lib.nixosSystem { ... };
        baz = nixpkgs.lib.nixosSystem { ... };
      };
      deploy-sh.hosts = self.nixosConfigurations;
    };
  }
  ```
</details>

<details>
  <summary>
    <b>2.</b> Import and configure the <code>deploy-sh</code> NixOS module.
  </summary>

  ```nix
  {
    inputs = {
      deploy-sh.url = "git+https://radicle.defelo.de/z392ZFR7AcScpaQqmTKUDkDj9FWMq.git";
    };
    outputs = {self, nixpkgs, deploy-sh, ...}: {
      nixosConfigurations.foo = nixpkgs.lib.nixosSystem {
        # ...
        modules = [
          # ...
          deploy-sh.nixosModules.default
          {
            deploy-sh.targetHost = "root@10.13.37.2";
          }
        ];
      };
      deploy-sh.hosts = self.nixosConfigurations;
    };
  }
  ```
</details>

<details>
  <summary>
    <b>3.</b> To be able to use the <code>deploy</code> command, add <code>deploy-sh</code> to your dev shell.
  </summary>

  ```nix
  {
    inputs = {
      deploy-sh = "git+https://radicle.defelo.de/z392ZFR7AcScpaQqmTKUDkDj9FWMq.git";
    };
    outputs = {self, nixpkgs, deploy-sh, ...}: let
      system = "x86_64-linux";
      pkgs = import nixpkgs {inherit system;};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          deploy-sh.packages.${system}.default
        ];
      };
    };
  }
  ```
</details>

## NixOS Module Options
See [flake.nix](https://radicle.defelo.de/nodes/radicle.defelo.de/rad:z392ZFR7AcScpaQqmTKUDkDj9FWMq/tree/flake.nix#L43)

## Usage
```
$ nix develop  # if you are not using direnv
$ deploy --help
Simple NixOS remote deployment tool (https://radicle.defelo.de/nodes/radicle.defelo.de/rad:z392ZFR7AcScpaQqmTKUDkDj9FWMq)

Usage: deploy [OPTIONS] [HOSTS]...

For each host, only the most recent options to its left are taken into account. For
example, `deploy --local foo bar --remote baz` will build hosts foo and bar locally,
and only baz on a remote build host.
All hosts are deployed if no host is specified explicitly.

Activation options:
  --switch        Build and activate the new configuration, and make it the boot default. (default)
  --boot          Build the new configuration and make it the boot default, but do not activate it.
  --test          Build and activate the new configuration, but do not add it to the boot menu.
  --dry-activate  Build the new configuration, but do not activate it.
  --reboot        Build the new configuration, make it the boot default and reboot into the new system.
  --check         Evaluate the new configuration and verify that it has been deployed correctly.
  --eval          Evaluate the new configuration, but neither build nor activate it.
  --build         Build the new configuration, but do not activate it.

  --[no-]sudo     Use sudo for commands that require privileges on the target host.

Diff options:
  --[no-]diff     Display differences between the current and new configuration
  --[no-]nvd      Display package differences between the current and new configuration. (default)

Host options:
  --local         Build the configuration locally and copy the new system to the target host.
  --remote        Build the configuration on the remote build host.
  --build-host    Set the host to build the configuration on.
  --target-host   Set the host to deploy the system on.

Build options:
  --[no-]cache    Set a path on the build host where to store a symlink to the new system to avoid garbage collection.
  --[no-]fetch    Copy the current system of the target host to the build host before building.

Options:
  -h  --help      Print help
```
