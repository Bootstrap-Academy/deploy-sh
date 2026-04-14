{
  lib,
  stdenvNoCC,
  makeWrapper,

  # runtime dependencies
  bash,
  coreutils,
  git,
  gnugrep,
  jq,
  nix-diff,
  nix-output-monitor,
  nixVersions,
  nvd,
  openssh,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "deploy-sh";
  version = "0.2.0";

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    install -DT ${./deploy.sh} $out/bin/deploy

    runHook postInstall
  '';

  runtimeDependencies = [
    bash
    coreutils
    git
    gnugrep
    jq
    nix-diff
    nix-output-monitor
    nixVersions.latest
    nvd
    openssh
  ];

  postFixup = ''
    wrapProgram $out/bin/deploy --set PATH ${lib.makeBinPath finalAttrs.runtimeDependencies}
  '';

  meta = {
    description = "Simple NixOS remote deployment tool";
    homepage = "https://radicle.defelo.de/nodes/radicle.defelo.de/rad:z392ZFR7AcScpaQqmTKUDkDj9FWMq";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ defelo ];
    mainProgram = "deploy";
  };
})
