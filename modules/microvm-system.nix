{ nixpkgs, microvm, lib, hostSystem, guestSystem, hostPkgs, vcpu, mem }:
let
  isDarwinHost = lib.hasSuffix "-darwin" hostSystem;
in
nixpkgs.lib.nixosSystem {
  system = guestSystem;
  modules = [
    microvm.nixosModules.microvm
    ({ pkgs, ... }: {
      system.stateVersion = "24.11";

      networking.hostName = "opencode-vm";
      networking.firewall.enable = false;
      zramSwap.enable = true;
      zramSwap.memoryPercent = 50;
      boot.consoleLogLevel = 0;
      boot.initrd.verbose = false;
      services.getty.greetingLine = "";
      services.getty.helpLine = "";
      boot.kernelParams = [
        "quiet"
        "loglevel=0"
        "rd.udev.log_level=0"
        "udev.log_priority=0"
        "rd.systemd.show_status=false"
        "systemd.show_status=false"
      ];

      services.getty.autologinUser = "root";
      users.users.root.shell = pkgs.bashInteractive;

      environment.loginShellInit = ''
        if [ -n "''${OPENCODE_BOOTSTRAPPED-}" ]; then
          return
        fi
        export OPENCODE_BOOTSTRAPPED=1

        mkdir -p /root/.config
        mkdir -p /root/.local/share
        mkdir -p /host-data/opencode/config

        if [ ! -f /host-data/opencode/config/.seeded ] \
          || [ -L /host-data/opencode/config/opencode.json ] \
          || [ ! -e /host-data/opencode/config/opencode.json ] \
          || [ ! -e /host-data/opencode/config/themes ] \
          || [ ! -e /host-data/opencode/config/skills ]; then
          find /host-data/opencode/config -mindepth 1 -maxdepth 1 -exec rm -rf {} +
          cp -aL /host-config/opencode/. /host-data/opencode/config/ 2>/dev/null || true
          touch /host-data/opencode/config/.seeded
        fi

        if [ ! -e /host-data/opencode/config/skills ] && [ -e /host-config/agents/skills ]; then
          ln -sfn /host-config/agents/skills /host-data/opencode/config/skills
        fi

        if [ ! -e /host-data/opencode/config/agents ] && [ -e /host-config/agents/agents ]; then
          ln -sfn /host-config/agents/agents /host-data/opencode/config/agents
        fi

        if [ ! -f /run/opencode-host/verbose ]; then
          printf '\033[2J\033[H'
        fi

        rm -rf /root/.config/opencode
        ln -sfn /host-data/opencode/config /root/.config/opencode

        rm -rf /root/.agents
        ln -sfn /host-config/agents /root/.agents

        rm -rf /root/.local/share/opencode
        ln -sfn /host-data/opencode /root/.local/share/opencode

        cd /project

        if [ -f /run/opencode-host/args ]; then
          mapfile -t OPENCODE_ARGS < /run/opencode-host/args
          ${pkgs.opencode}/bin/opencode "''${OPENCODE_ARGS[@]}"
        else
          ${pkgs.opencode}/bin/opencode
        fi

        /run/current-system/sw/bin/poweroff -f || true
        exit 0
      '';

      environment.systemPackages = with pkgs; [
        opencode
        bashInteractive
        git
      ];

      microvm = {
        hypervisor = if isDarwinHost then "vfkit" else "qemu";
        vfkit.logLevel = lib.mkIf isDarwinHost "error";
        virtiofsd.package = lib.mkIf isDarwinHost hostPkgs.bash;
        vcpu = vcpu;
        mem = mem;
        socket = "opencode.sock";

        extraArgsScript = lib.mkIf (!isDarwinHost) "${pkgs.writeShellScript "qemu-extra-args" ''
          set -euo pipefail

          port_file="runtime/port"
          if [ ! -s "$port_file" ]; then
            exit 0
          fi

          port="$(<"$port_file")"
          case "$port" in
            ""|*[!0-9]*)
              exit 0
              ;;
          esac

          printf -- "-netdev user,id=vmfwd,hostfwd=tcp:127.0.0.1:%s-:%s -device virtio-net-pci,netdev=vmfwd,mac=02:00:00:00:10:02\n" "$port" "$port"
        ''}";

        interfaces = [
          {
            type = "user";
            id = "vmnet";
            mac = "02:00:00:00:10:01";
          }
        ];

        shares = [
          {
            proto = if isDarwinHost then "virtiofs" else "9p";
            tag = "ro-store";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            readOnly = true;
          }
          {
            proto = if isDarwinHost then "virtiofs" else "9p";
            tag = "workdir";
            source = "workdir";
            mountPoint = "/project";
          }
          {
            proto = if isDarwinHost then "virtiofs" else "9p";
            tag = "opencode-config";
            source = "config-opencode";
            mountPoint = "/host-config/opencode";
            readOnly = true;
          }
          {
            proto = if isDarwinHost then "virtiofs" else "9p";
            tag = "agents-config";
            source = "agents";
            mountPoint = "/host-config/agents";
            readOnly = true;
          }
          {
            proto = if isDarwinHost then "virtiofs" else "9p";
            tag = "opencode-data";
            source = "data-opencode";
            mountPoint = "/host-data/opencode";
          }
          {
            proto = if isDarwinHost then "virtiofs" else "9p";
            tag = "runtime-args";
            source = "runtime";
            mountPoint = "/run/opencode-host";
            readOnly = true;
          }
        ];

        vmHostPackages = lib.mkIf isDarwinHost nixpkgs.legacyPackages.${hostSystem};
      };
    })
  ];
}
