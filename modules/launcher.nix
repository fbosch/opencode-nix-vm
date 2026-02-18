{
  hostPkgs,
  hostSystem,
  guestSystem,
}:
hostPkgs.writeShellApplication {
  name = "opencode-microvm";
  runtimeInputs = with hostPkgs; [
    jq
    nix
    openssh
  ];
  text = ''
    exec ${hostPkgs.bash}/bin/bash ${./opencode-launcher.sh} ${hostSystem} ${guestSystem} "$@"
  '';
}
