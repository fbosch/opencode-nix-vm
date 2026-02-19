{
  hostPkgs,
  hostSystem,
  guestSystem,
}:
let
  darwinBuilderScript = hostPkgs.writeScript "opencode-darwin-builder.sh" (builtins.readFile ./opencode-darwin-builder.sh);
  launcherScript = hostPkgs.writeScript "opencode-launcher.sh" (builtins.readFile ./opencode-launcher.sh);
in
hostPkgs.writeShellApplication {
  name = "opencode-microvm";
  runtimeInputs = with hostPkgs; [
    jq
    nix
    openssh
  ];
  text = ''
    exec ${hostPkgs.bash}/bin/bash ${launcherScript} ${hostSystem} ${guestSystem} ${darwinBuilderScript} "$@"
  '';
}
