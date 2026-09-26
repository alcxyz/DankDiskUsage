{ lib, buildGoModule, stdenv, stdenvNoCC, python3, makeWrapper, sqlite
, version ? (builtins.fromJSON (builtins.readFile ./plugin.json)).version
, revision ? null, release ? false, withCollector ? true }:
let
  metadata = import ./build-metadata.nix { inherit lib version revision release; };
in
if !withCollector then stdenvNoCC.mkDerivation {
  pname = lib.toLower metadata.config.pluginDirectory;
  version = metadata.version;
  src = metadata.source;
  nativeBuildInputs = [ python3 ];
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    python3 scripts/package.py --stage-only --output "$out" \
      --revision ${lib.escapeShellArg metadata.revision} ${lib.optionalString release "--release"}
    runHook postInstall
  '';
}
else buildGoModule {
  pname = lib.toLower metadata.config.pluginDirectory;
  version = metadata.version;
  src = metadata.source;
  vendorHash = null;
  subPackages = [ "cmd/dankdiskusage-collector" ];
  ldflags = [ "-s" "-w" "-X main.version=${metadata.version}" "-X main.revision=${metadata.revision}" ];
  nativeBuildInputs = [ python3 makeWrapper ];
  postInstall = ''
    python3 scripts/package.py --stage-only --output "$out" \
      --revision ${lib.escapeShellArg metadata.revision} ${lib.optionalString release "--release"}
    wrapProgram "$out/bin/dankdiskusage-collector" --prefix PATH : ${lib.makeBinPath [ sqlite ]}
    install -Dm644 systemd/dankdiskusage-collector.timer "$out/lib/systemd/user/dankdiskusage-collector.timer"
    install -Dm644 systemd/dankdiskusage-collector.service "$out/lib/systemd/user/dankdiskusage-collector.service"
    substituteInPlace "$out/lib/systemd/user/dankdiskusage-collector.service" \
      --replace-fail '%h/.local/bin/dankdiskusage-collector' "$out/bin/dankdiskusage-collector"
    ${lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
      test "$($out/bin/dankdiskusage-collector version)" = ${lib.escapeShellArg metadata.version}
    ''}
  '';
  meta = with lib; {
    description = "Disk usage widget and optional cached storage collector for DankMaterialShell";
    homepage = "https://github.com/alcxyz/DankDiskUsage";
    license = licenses.mit;
    mainProgram = "dankdiskusage-collector";
  };
}
