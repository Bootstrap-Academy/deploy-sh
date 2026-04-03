#!/usr/bin/env bash

set -e

log() {
  local prefix=""
  if [[ -n "$host" ]]; then
    prefix="[$host] "
  fi
  echo -e "\e[1m${2:-\e[34m}$prefix$1\e[0m"
}

sshHost() { echo "${1%:*}"; }
sshPort() { [[ "$1" =~ :[0-9]+$ ]] && echo "-p${1##*:}" || echo -p22; }
nixSshHost() { echo "ssh://$(sshHost $1)"; }
nixSshPort() { echo "NIX_SSHOPTS=$(sshPort $1)"; }

nix="nix --extra-experimental-features nix-command --extra-experimental-features flakes"

extractKernelPaths() {
  build=$($nix derivation show "$1^*" | jq -r 'values | .[].env.buildCommand')
  for path in initrd kernel kernel-modules; do
    grep -o "^ln -s .* \\\$out/$path\$" <<< "$build" | cut -d' ' -f3
  done
}

deploy() {
  host="$1"
  trap "log 'Deployment of $host failed!' \"\e[31m\"" ERR

  log "Starting deployment of $host ($action)" "\e[33m"
  log "Evaluating configuration"
  local config
  config=$($nix build --no-link --print-out-paths "${extraEvalOptions[@]}" ".#nixosConfigurations.\"$host\".config.deploy-sh._config")
  source "$config"
  log "Evaluation succeeded!" "\e[32m"

  if [[ -n "$targetHostOverride" ]]; then
    targetHost="$targetHostOverride"
  fi

  if [[ -n "$buildHostOverride" ]]; then
    buildHost="$buildHostOverride"
  elif [[ $buildLocal = 1 ]]; then
    buildHost=""
  elif [[ $buildRemote = 1 ]]; then
    buildHost="$targetHost"
  fi

  if [[ -n "$buildCacheOverride" ]]; then
    buildCache="$buildCacheOverride"
  fi
  if [[ "$buildCache" = "\0" ]]; then
    buildCache=""
  fi

  if [[ -n "$useSudoOverride" ]]; then
    useSudo="$useSudoOverride"
  fi
  if [[ "$useSudo" = 1 ]]; then
    sudoCmd="sudo -S --prompt= --"
  else
    sudoCmd=""
  fi

  if [[ -n "$systemCopyStrategyOverride" ]]; then
    systemCopyStrategy="$systemCopyStrategyOverride"
  fi

  warnOrError="\e[33m"
  if [[ "$action" = "check" ]]; then
    warnOrError="\e[31m"
  fi

  if [[ $nvd = 1 ]] || [[ $diff = 1 ]] || [[ "$action" = "check" ]]; then
    log "Copying current derivation from target host $targetHost"
    if ! currentDrv=$(ssh $(sshPort "$targetHost") $(sshHost "$targetHost") nix-store --query --deriver /run/current-system); then
      log "Failed to lookup current system on $targetHost" "\e[31m"
      return 1
    fi

    if [[ "$currentDrv" = "$systemDrv" ]]; then
      log "Current and new configuration are the same" "\e[32m"

      if [[ "$action" = "check" ]]; then
        if ! currentProfile=$(ssh $(sshPort "$targetHost") $(sshHost "$targetHost") readlink -f /nix/var/nix/profiles/system); then
          log "Failed to lookup current system profile on $targetHost" "\e[31m"
          return 1
        fi
        if [[ "$currentProfile" != "$system" ]]; then
          log "The current system profile does not match the running system" "\e[31m"
          return 2
        else
          log "The current system profile matches the running system" "\e[32m"
        fi

        if ! ssh $(sshPort "$targetHost") $(sshHost "$targetHost") 'cmp -s <(readlink /run/booted-system/{initrd,kernel,kernel-modules}) <(readlink /run/current-system/{initrd,kernel,kernel-modules})'; then
          log "The target host hasn't been rebooted yet" "\e[31m"
          return 2
        else
          log "No reboot is necessary" "\e[32m"
        fi
      fi
    else
      if ! [[ -e "$currentDrv" ]] && ! env $(nixSshPort "$targetHost") $nix copy --derivation --from $(nixSshHost "$targetHost") "$currentDrv^*"; then
        if [[ -z "$buildHost" ]] || [[ "$targetHost" = "$buildHost" ]]; then
          log "Failed to fetch current system from $targetHost" "\e[31m"
          return 1
        fi

        log "Failed to fetch current system from $targetHost" "\e[33m"
        if ! env $(nixSshPort "$buildHost") $nix copy --derivation --from $(nixSshHost "$buildHost") "$currentDrv^*"; then
          log "Failed to fetch current system from $buildHost" "\e[31m"
          return 1
        fi
      fi

      log "Current and new configuration differ:" "$warnOrError"
      if [[ $diff = 1 ]]; then
        nix-diff "$currentDrv" "$systemDrv"
      fi
      if [[ $nvd = 1 ]]; then
        nvd diff "$currentDrv" "$systemDrv"
      fi

      if [[ "$(extractKernelPaths $currentDrv)" != "$(extractKernelPaths $systemDrv)" ]]; then
        log "Reboot is recommended after deploying this configuration!" "\e[33m"
      fi

      if [[ "$action" = "check" ]]; then
        return 2
      fi
    fi
  fi

  if [[ "$action" =~ ^(eval|check)$ ]]; then
    return
  fi

  if [[ -z "$buildHost" ]]; then
    log "Building locally, then deploying to $targetHost" "\e[36m"
  elif [[ "$buildHost" = "$targetHost" ]]; then
    log "Building and deploying to $targetHost" "\e[36m"
  else
    log "Building on $buildHost, then deploying to $targetHost" "\e[36m"
  fi
  if [[ -n "$buildCache" ]]; then
    if [[ -z "$buildHost" ]]; then
      log "Cache the system at $buildCache" "\e[36m"
    else
      log "Cache the system on $buildHost at $buildCache" "\e[36m"
    fi
  fi
  log "System path: $system" "\e[0m"
  log "System derivation: $systemDrv" "\e[0m"

  if [[ -z "$buildHost" ]]; then
    nomBin="nom"
  else
    nomBin="$nom/bin/nom"
  fi
  local nomPipe="--log-format internal-json -v |& $nomBin --json"

  if [[ "$buildHost" != "$targetHost" ]] && [[ "$pushDerivations" = "1" ]]; then
    log "Copying derivations to target host $targetHost"
    env $(nixSshPort "$targetHost") $nix copy --derivation --to $(nixSshHost "$targetHost") "$systemDrv^*"
  fi

  if [[ -n "$buildHost" ]]; then
    log "Copying derivations to build host $buildHost"
    env $(nixSshPort "$buildHost") $nix copy --derivation --to $(nixSshHost "$buildHost") "$systemDrv^*" "$nomDrv^*"

    if [[ $fetch = 1 ]] && [[ "$targetHost" != "$buildHost" ]]; then
      if oldSystem=$(ssh $(sshPort "$targetHost") $(sshHost "$targetHost") readlink /run/current-system); then
        case "$systemCopyStrategy" in
          direct)
            log "Copying old system from $targetHost to $buildHost"
            ssh $(sshPort "$buildHost") $(sshHost "$buildHost") env $(nixSshPort "$targetHost") $nix copy --no-check-sigs --from $(nixSshHost "$targetHost") "$oldSystem"
            ;;
          via-local)
            log "Copying old system from $targetHost"
            env $(nixSshPort "$targetHost") $nix copy --no-check-sigs --from $(nixSshHost "$targetHost") "$oldSystem"
            log "Copying old system to $buildHost"
            env $(nixSshPort "$buildHost") $nix copy --to $(nixSshHost "$buildHost") "$oldSystem"
            ;;
        esac
      else
        log "Failed to lookup current system on $targetHost" "\e[31m"
      fi
    fi

    log "Building system for $targetHost on $buildHost"
    ssh $(sshPort "$buildHost") $(sshHost "$buildHost") $nix build --no-link "$nomDrv^*"
    if [[ -n "$buildCache" ]]; then
      ssh $(sshPort "$buildHost") $(sshHost "$buildHost") "$nix build -o \"$buildCache\" \"$systemDrv^*\" $nomPipe"
    else
      ssh $(sshPort "$buildHost") $(sshHost "$buildHost") "$nix build --no-link \"$systemDrv^*\" $nomPipe"
    fi

    if [[ "$targetHost" != "$buildHost" ]]; then
      case "$systemCopyStrategy" in
        direct)
          log "Copying system from $buildHost to $targetHost"
          ssh $(sshPort "$buildHost") $(sshHost "$buildHost") env $(nixSshPort "$targetHost") $nix copy --to $(nixSshHost "$targetHost") "$system"
          ;;
        via-local)
          log "Copying system from $buildHost"
          env $(nixSshPort "$buildHost") $nix copy --no-check-sigs --from $(nixSshHost "$buildHost") "$system"
          log "Copying system to $targetHost"
          env $(nixSshPort "$targetHost") $nix copy --to $(nixSshHost "$targetHost") "$system"
          ;;
      esac
    fi
  else
    if [[ $fetch = 1 ]]; then
      if oldSystem=$(ssh $(sshPort "$targetHost") $(sshHost "$targetHost") readlink /run/current-system); then
        log "Fetching old system from $targetHost"
        env $(nixSshPort "$targetHost") $nix copy --no-check-sigs --from $(nixSshHost "$targetHost") "$oldSystem"
      else
        log "Failed to lookup current system on $targetHost" "\e[31m"
      fi
    fi

    log "Building system for $targetHost locally"
    if [[ -n "$buildCache" ]]; then
      bash -c "$nix build -o \"$buildCache\" \"$systemDrv^*\" $nomPipe"
    else
      bash -c "$nix build --no-link \"$systemDrv^*\" $nomPipe"
    fi

    log "Copying system to $targetHost"
    env $(nixSshPort "$targetHost") $nix copy --to $(nixSshHost "$targetHost") "$system"
  fi

  if [[ "$action" = "build" ]]; then
    return
  fi

  log "Activating system on $targetHost ($action)"
  if [[ "$useSudo" = 1 ]]; then
    ok=0
    for i in {1..3}; do
      read -rs -p "[sudo] password for $targetHost: " sudoPassword
      echo
      if echo -n "$sudoPassword" | ssh $(sshPort "$targetHost") $(sshHost "$targetHost") sudo -S --prompt= -v; then
        ok=1
        break
      fi
    done
    if [[ $ok = 0 ]]; then return 1; fi
  else
    sudoPassword=""
  fi
  if [[ "$action" =~ ^(switch|boot|reboot)$ ]]; then
    echo -n "$sudoPassword" | ssh $(sshPort "$targetHost") $(sshHost "$targetHost") $sudoCmd nix-env -p /nix/var/nix/profiles/system --set "$system"
  fi
  if [[ "$action" = "reboot" ]]; then
    echo -n "$sudoPassword" | ssh $(sshPort "$targetHost") $(sshHost "$targetHost") $sudoCmd "$system/bin/switch-to-configuration" boot
    log "Rebooting $targetHost"
    echo -n "$sudoPassword" | ssh $(sshPort "$targetHost") $(sshHost "$targetHost") $sudoCmd reboot
    log "Waiting for $targetHost to reboot"
    sleep 5
    while ! ssh $(sshPort "$targetHost") $(sshHost "$targetHost") -o StrictHostKeyChecking=yes true; do
      sleep 1
    done
  else
    echo -n "$sudoPassword" | ssh $(sshPort "$targetHost") $(sshHost "$targetHost") $sudoCmd "$system/bin/switch-to-configuration" "$action"
  fi

  if ! ssh $(sshPort "$targetHost") $(sshHost "$targetHost") 'cmp -s <(readlink /run/booted-system/{initrd,kernel,kernel-modules}) <(readlink /run/current-system/{initrd,kernel,kernel-modules})'; then
    rebootHosts+=("$host")
    log "It is recommended to reboot the target host now!" "\e[33m"
  fi

  log "Deployment of $host succeeded!" "\e[32m"
}

for arg in $@; do
  if [[ "$arg" =~ ^(-h|--help)$ ]]; then
    echo -e "Simple NixOS remote deployment tool (\e[36mhttps://radicle.defelo.de/nodes/radicle.defelo.de/rad:z392ZFR7AcScpaQqmTKUDkDj9FWMq\e[0m)"
    echo -e
    echo -e "\e[1m\e[32mUsage: \e[36mdeploy [OPTIONS] [HOSTS]...\e[0m"
    echo -e
    echo -e "For each host, only the most recent options to its left are taken into account. For"
    echo -e "example, \`\e[36mdeploy --local foo bar --remote baz\e[0m\` will build hosts foo and bar locally,"
    echo -e "and only baz on a remote build host."
    echo -e "All hosts are deployed if no host is specified explicitly."
    echo -e
    echo -e "\e[1m\e[32mActivation options:\e[0m"
    echo -e "\e[1m\e[36m  --switch         \e[0m Build and activate the new configuration, and make it the boot default. (default)"
    echo -e "\e[1m\e[36m  --boot           \e[0m Build the new configuration and make it the boot default, but do not activate it."
    echo -e "\e[1m\e[36m  --test           \e[0m Build and activate the new configuration, but do not add it to the boot menu."
    echo -e "\e[1m\e[36m  --dry-activate   \e[0m Build the new configuration, but only dry-activate it."
    echo -e "\e[1m\e[36m  --reboot         \e[0m Build the new configuration, make it the boot default and reboot into the new system."
    echo -e "\e[1m\e[36m  --check          \e[0m Evaluate the new configuration and verify that it has been deployed correctly."
    echo -e "\e[1m\e[36m  --eval           \e[0m Evaluate the new configuration, but neither build nor activate it."
    echo -e "\e[1m\e[36m  --build          \e[0m Build the new configuration, but do not activate it."
    echo -e
    echo -e "\e[1m\e[36m  --[no-]sudo      \e[0m Use sudo for commands that require privileges on the target host."
    echo -e
    echo -e "\e[1m\e[32mDiff options:\e[0m"
    echo -e "\e[1m\e[36m  --[no-]diff      \e[0m Display differences between the current and new configuration"
    echo -e "\e[1m\e[36m  --[no-]nvd       \e[0m Display package differences between the current and new configuration. (default)"
    echo -e
    echo -e "\e[1m\e[32mHost options:\e[0m"
    echo -e "\e[1m\e[36m  --local          \e[0m Build the configuration locally and copy the new system to the target host."
    echo -e "\e[1m\e[36m  --remote         \e[0m Build the configuration on the remote build host."
    echo -e "\e[1m\e[36m  --build-host     \e[0m Set the host to build the configuration on."
    echo -e "\e[1m\e[36m  --target-host    \e[0m Set the host to deploy the system on."
    echo -e "\e[1m\e[36m  --copy-direct    \e[0m Copy the new system directly from build host to target host."
    echo -e "\e[1m\e[36m  --copy-via-local \e[0m Copy the new system from build host to localhost and then from localhost to target host."
    echo -e
    echo -e "\e[1m\e[32mBuild options:\e[0m"
    echo -e "\e[1m\e[36m  --[no-]cache     \e[0m Set a path on the build host where to store a symlink to the new system to avoid garbage collection."
    echo -e "\e[1m\e[36m  --[no-]fetch     \e[0m Copy the current system of the target host to the build host before building."
    echo -e
    echo -e "\e[1m\e[32mOptions:\e[0m"
    echo -e "\e[1m\e[36m  -h  --help       \e[0m Print help"
    exit
  fi
done

action=switch
useSudoOverride=""
buildLocal=0
buildRemote=0
buildHostOverride=""
targetHostOverride=""
buildCacheOverride=""
systemCopyStrategyOverride=""
fetch=0
deployed=0
diff=0
nvd=1
extraEvalOptions=()

rebootHosts=()

while [[ $# -gt 0 ]]; do
  i="$1"; shift 1
  case "$i" in
    --switch|--boot|--test|--dry-activate|--reboot|--eval|--build|--check)
      action=${i#"--"}
      ;;
    --sudo)
      useSudoOverride=1
      ;;
    --no-sudo)
      useSudoOverride=0
      ;;
    --diff)
      diff=1
      ;;
    --no-diff)
      diff=0
      ;;
    --nvd)
      nvd=1
      ;;
    --no-nvd)
      nvd=0
      ;;
    --local)
      buildLocal=1
      buildRemote=0
      buildHostOverride=""
      ;;
    --remote)
      buildLocal=0
      buildRemote=1
      buildHostOverride=""
      ;;
    --buildHost|--build-host)
      buildLocal=0
      buildRemote=0
      buildHostOverride="$1"; shift 1
      ;;
    --targetHost|--target-host)
      targetHostOverride="$1"; shift 1
      ;;
    --copy-direct)
      systemCopyStrategyOverride="direct"
      ;;
    --copy-via-local)
      systemCopyStrategyOverride="via-local"
      ;;
    --cache)
      buildCacheOverride="$1"; shift 1
      ;;
    --no-cache)
      buildCacheOverride="\0"
      ;;
    --fetch)
      fetch=1
      ;;
    --no-fetch)
      fetch=0
      ;;
    --override-input)
      extraEvalOptions+=("$i" "$1" "$2")
      shift 2
      ;;
    -*)
      echo -e "\e[1m\e[31mUnknown flag: $i\e[0m"
      echo -e "For more information, try '\e[1m\e[36m--help\e[0m'."
      exit 1
      ;;
    *)
      if [[ $deployed = 1 ]]; then echo; fi
      deploy "$i"
      deployed=1
      ;;
  esac
done

if [[ $deployed = 0 ]]; then
  for host in $($nix eval --raw .#deploy-sh.hosts --apply 'hosts: builtins.concatStringsSep " " (builtins.attrNames hosts)'); do
    if [[ $deployed = 1 ]]; then echo; fi
    deploy "$host"
    deployed=1
  done
fi

unset host
if [[ ${#rebootHosts[@]} -ne 0 ]]; then
  log "\nIt is recommended to reboot the following target hosts now:" "\e[33m"
  for h in ${rebootHosts[@]}; do
    log " - $h" "\e[33m"
  done
fi
