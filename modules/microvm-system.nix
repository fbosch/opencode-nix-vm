{ nixpkgs
, microvm
, lib
, hostSystem
, guestSystem
, hostPkgs
,
}:
let
  isDarwinHost = lib.hasSuffix "-darwin" hostSystem;
  # vfkit (Darwin) uses virtio-serial → hvc0; qemu (Linux) uses serial → ttyS0
  ttyDevice = if isDarwinHost then "hvc0" else "ttyS0";
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

        # Temporary: SSH for debugging
        services.openssh.enable = true;
        services.openssh.settings.PermitRootLogin = "yes";
        users.users.root.openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJl/WCQsXEkE7em5A6d2Du2JAWngIPfA8sVuJP/9cuyq fbb@nixos"
        ];
        boot.tmp.useTmpfs = true;
        boot.tmp.cleanOnBoot = true;
        services.journald.storage = "volatile";
        zramSwap.enable = true;
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
        security.apparmor.enable = true;
        security.apparmor.policies.opencode = {
          state = "enforce";
          path = ./opencode.apparmor;
        };
        nix.enable = true;
        nix.settings.experimental-features = [
          "nix-command"
          "flakes"
        ];
        environment.sessionVariables.PATH = lib.mkForce "/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin";
        environment.systemPackages = with pkgs; [
          opencode
          bashInteractive
          git
          nix
          gh
          bun
          jq
          ripgrep
          fd
          curl
          python3
          nodejs_25
        ];

        systemd.services."serial-getty@${ttyDevice}".enable = false;

        systemd.services.opencode = {
          description = "OpenCode session";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "simple";
            Environment = [ "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin" ];
            StandardInput = "tty";
            StandardOutput = "tty";
            StandardError = "tty";
            TTYPath = "/dev/${ttyDevice}";
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
            AppArmorProfile = "opencode";
            ExecStart = "${pkgs.writeShellScript "opencode-session" ''
              exec ${pkgs.bash}/bin/bash ${./opencode-session.sh} ${pkgs.opencode}/bin/opencode
            ''}";
          };
        };

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
