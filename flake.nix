{
  description = "Run OpenCode in a sandboxed microVM";

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm }:
    let
      lib = nixpkgs.lib;
      hostSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllHostSystems = f: lib.genAttrs hostSystems (hostSystem: f hostSystem);
      guestSystemFor = hostSystem: lib.replaceString "-darwin" "-linux" hostSystem;

      mkPackageSet = hostSystem:
        let
          hostPkgs = nixpkgs.legacyPackages.${hostSystem};
          guestSystem = guestSystemFor hostSystem;

          mkRunner = resources:
            let
              vm = import ./modules/microvm-system.nix {
                inherit nixpkgs microvm lib hostSystem guestSystem hostPkgs;
                inherit (resources) vcpu mem;
              };
            in
            vm.config.microvm.declaredRunner;

          vmSmall = mkRunner { vcpu = 2; mem = 2048; };
          vmMedium = mkRunner { vcpu = 4; mem = 4096; };
          vmLarge = mkRunner { vcpu = 8; mem = 8192; };

          launcher = import ./modules/launcher.nix {
            inherit hostPkgs hostSystem guestSystem;
          };
        in
        {
          default = launcher;
          vm = vmMedium;
          vm-small = vmSmall;
          vm-medium = vmMedium;
          vm-large = vmLarge;
          launch = launcher;
        };
    in
    {
      packages = forAllHostSystems mkPackageSet;

      apps = forAllHostSystems (hostSystem:
        let
          pkg = self.packages.${hostSystem}.launch;
        in
        {
          default = {
            type = "app";
            program = "${pkg}/bin/opencode-microvm";
          };
          run = {
            type = "app";
            program = "${pkg}/bin/opencode-microvm";
          };
        });
    };
}
