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
        zramSwap.enable = false;
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
        nix.enable = true;

        systemd.services."serial-getty@ttyS0".enable = false;

        systemd.services.opencode = {
          description = "OpenCode session";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "simple";
            StandardInput = "tty";
            StandardOutput = "tty";
            StandardError = "tty";
            TTYPath = "/dev/ttyS0";
            TTYReset = true;
            TTYVHangup = true;
            TTYVTDisallocate = true;
            UMask = "0077";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            RestrictSUIDSGID = true;
            RestrictRealtime = true;
            LockPersonality = true;
            SystemCallArchitectures = "native";
            ExecStart = "${pkgs.writeShellScript "opencode-session" ''
              exec ${pkgs.bash}/bin/bash ${./opencode-session.sh} ${pkgs.opencode}/bin/opencode
            ''}";
          };
        };

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
