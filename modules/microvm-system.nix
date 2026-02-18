{
  nixpkgs,
  microvm,
  lib,
  hostSystem,
  guestSystem,
  hostPkgs,
}:
let
  isDarwinHost = lib.hasSuffix "-darwin" hostSystem;
in
nixpkgs.lib.nixosSystem {
  system = guestSystem;
  modules = [
    microvm.nixosModules.microvm
    (
      { pkgs, ... }:
      {
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
          "systemd.show_status=false"
          "rd.systemd.show_status=false"
        ];
        nix.enable = false;

        services.getty.autologinUser = "root";
        users.users.root.shell = pkgs.bashInteractive;

        environment.loginShellInit = ''
          if [ -n "''${OPENCODE_BOOTSTRAPPED-}" ]; then
            return
          fi
          export OPENCODE_BOOTSTRAPPED=1

          mkdir -p /root/.config
          mkdir -p /root/.local/share
          mkdir -p /root/.local/state
          mkdir -p /root/.cache
          mkdir -p /host-data/opencode/config
          mkdir -p /host-data/opencode/state
          mkdir -p /host-data/opencode/cache

          if [ ! -f /host-data/opencode/config/.seeded ]; then
            cp -aL /host-config/opencode/. /host-data/opencode/config/ 2>/dev/null || true
            touch /host-data/opencode/config/.seeded
          fi

          if [ -L /host-data/opencode/config/skills ]; then
            skills_link_target="$(readlink /host-data/opencode/config/skills || true)"
            case "$skills_link_target" in
              /host-config/*)
                rm -f /host-data/opencode/config/skills
                ;;
            esac
          fi

          if [ -L /host-data/opencode/config/themes ]; then
            themes_link_target="$(readlink /host-data/opencode/config/themes || true)"
            case "$themes_link_target" in
              /host-config/*)
                rm -f /host-data/opencode/config/themes
                ;;
            esac
          fi

          if [ -L /host-data/opencode/config/agents ]; then
            agents_link_target="$(readlink /host-data/opencode/config/agents || true)"
            case "$agents_link_target" in
              /host-config/*)
                rm -f /host-data/opencode/config/agents
                ;;
            esac
          fi

          if [ ! -e /host-data/opencode/config/opencode.json ] && [ -e /host-config/opencode/opencode.json ]; then
            cp -aL /host-config/opencode/opencode.json /host-data/opencode/config/opencode.json 2>/dev/null || true
          fi

          if [ ! -e /host-data/opencode/config/themes ] && [ -e /host-config/opencode/themes ]; then
            cp -aL /host-config/opencode/themes /host-data/opencode/config/themes 2>/dev/null || true
          fi

          if [ ! -e /host-data/opencode/config/skills ] && [ -e /host-config/opencode/skills ]; then
            cp -aL /host-config/opencode/skills /host-data/opencode/config/skills 2>/dev/null || true
          fi

          if [ ! -e /host-data/opencode/config/skills ] && [ -e /host-config/agents/skills ]; then
            cp -aL /host-config/agents/skills /host-data/opencode/config/skills 2>/dev/null || true
          fi

          if [ ! -e /host-data/opencode/config/agents ] && [ -e /host-config/agents/agents ]; then
            cp -aL /host-config/agents/agents /host-data/opencode/config/agents 2>/dev/null || true
          fi

          if [ ! -f /run/opencode-host/verbose ]; then
            printf '\033[2J\033[H'
          fi

          ensure_symlink() {
            local src="$1"
            local dst="$2"

            if [ -L "$dst" ]; then
              local current_target
              current_target="$(readlink "$dst" || true)"
              if [ "$current_target" = "$src" ]; then
                return
              fi
            fi

            rm -rf "$dst"
            ln -sfn "$src" "$dst"
          }

          ensure_symlink /host-data/opencode/config /root/.config/opencode
          ensure_symlink /host-config/agents /root/.agents
          ensure_symlink /host-data/opencode /root/.local/share/opencode
          ensure_symlink /host-data/opencode/state /root/.local/state/opencode
          ensure_symlink /host-data/opencode/cache /root/.cache/opencode

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
          vcpu = 4;
          mem = 3072;
          socket = "opencode.sock";

          extraArgsScript =
            lib.mkIf (!isDarwinHost)
              "${pkgs.writeShellScript "qemu-extra-args" ''
                set -euo pipefail

                port_file="/tmp/opencode-microvm/runtime/port"
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
              source = "/tmp/opencode-microvm/workdir";
              mountPoint = "/project";
            }
            {
              proto = if isDarwinHost then "virtiofs" else "9p";
              tag = "opencode-config";
              source = "/tmp/opencode-microvm/config-opencode";
              mountPoint = "/host-config/opencode";
              readOnly = true;
            }
            {
              proto = if isDarwinHost then "virtiofs" else "9p";
              tag = "agents-config";
              source = "/tmp/opencode-microvm/agents";
              mountPoint = "/host-config/agents";
              readOnly = true;
            }
            {
              proto = if isDarwinHost then "virtiofs" else "9p";
              tag = "opencode-data";
              source = "/tmp/opencode-microvm/data-opencode";
              mountPoint = "/host-data/opencode";
            }
            {
              proto = if isDarwinHost then "virtiofs" else "9p";
              tag = "runtime-args";
              source = "/tmp/opencode-microvm/runtime";
              mountPoint = "/run/opencode-host";
              readOnly = true;
            }
          ];

          vmHostPackages = lib.mkIf isDarwinHost nixpkgs.legacyPackages.${hostSystem};
        };
      }
    )
  ];
}
