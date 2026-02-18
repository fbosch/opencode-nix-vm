{ hostPkgs, hostSystem, guestSystem }:
hostPkgs.writeShellApplication {
  name = "opencode-microvm";
  runtimeInputs = with hostPkgs; [ jq nix openssh ];
  text = ''
        set -euo pipefail

        hash_string() {
          if command -v sha256sum >/dev/null 2>&1; then
            printf '%s' "$1" | sha256sum | awk '{print $1}'
          else
            printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
          fi
        }

        project_id="$(hash_string "$PWD" | cut -c1-16)"
        state_dir="/tmp/opencode-microvm/$project_id"
        runtime_dir="$state_dir/runtime"
        port_file="$runtime_dir/port"
        verbose_file="$runtime_dir/verbose"
        nix_build_args=()
        vm_verbose=0
        vm_size=""
        forwarded_args=()

        while [ "$#" -gt 0 ]; do
          case "$1" in
            --verbose)
              vm_verbose=1
              ;;
            --vm-size)
              shift
              if [ "$#" -eq 0 ]; then
                echo "error: --vm-size requires a value (small|medium|large)" >&2
                exit 1
              fi
              vm_size="$1"
              ;;
            --vm-size=*)
              vm_size="''${1#--vm-size=}"
              ;;
            *)
              forwarded_args+=("$1")
              ;;
          esac
          shift
        done

        detect_host_mem_gib() {
          if [[ "${hostSystem}" == *-darwin ]]; then
            local bytes
            bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
            echo $(( bytes / 1024 / 1024 / 1024 ))
          else
            local kib
            kib="$(awk '/MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"
            echo $(( kib / 1024 / 1024 ))
          fi
        }

        detect_host_cpus() {
          if [[ "${hostSystem}" == *-darwin ]]; then
            sysctl -n hw.ncpu 2>/dev/null || echo 1
          else
            nproc 2>/dev/null || echo 1
          fi
        }

        if [ -z "$vm_size" ]; then
          vm_size="''${OPENCODE_VM_SIZE:-}"
        fi

        if [ -z "$vm_size" ]; then
          host_mem_gib="$(detect_host_mem_gib)"
          host_cpus="$(detect_host_cpus)"
          if [ "$host_mem_gib" -lt 8 ] || [ "$host_cpus" -le 4 ]; then
            vm_size="small"
          elif [ "$host_mem_gib" -lt 16 ] || [ "$host_cpus" -le 8 ]; then
            vm_size="medium"
          else
            vm_size="large"
          fi
        fi

        case "$vm_size" in
          small|medium|large)
            ;;
          *)
            echo "error: invalid VM size '$vm_size' (expected: small, medium, large)" >&2
            exit 1
            ;;
        esac

        if [[ "${hostSystem}" == *-darwin ]]; then
          builders=""

          if [ -n "''${OPENCODE_VM_BUILDERS:-}" ]; then
            builders="$OPENCODE_VM_BUILDERS"
          else
            builders="$(nix config show --json | jq -r '.builders.value // ""')"
          fi

          if [ -z "$builders" ]; then
            builder_state_dir="/tmp/opencode-linux-builder"
            builder_log="$builder_state_dir/bootstrap.log"
            builder_ssh_key="$builder_state_dir/keys/builder_ed25519"
            builder_ssh_opts=(
              -i "$builder_ssh_key"
              -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null
              -o LogLevel=ERROR
            )
            mkdir -p "$builder_state_dir"

            if ! ssh "''${builder_ssh_opts[@]}" -p 31022 builder@127.0.0.1 true >/dev/null 2>&1; then
              echo "info: starting local darwin linux-builder in background" >&2
              (
                cd "$builder_state_dir"
                nohup nix run --accept-flake-config nixpkgs#darwin.linux-builder </dev/null >"$builder_log" 2>&1 &
              )
            fi

            for _ in $(seq 1 120); do
              if [ -f "$builder_ssh_key" ] && ssh "''${builder_ssh_opts[@]}" -p 31022 builder@127.0.0.1 true >/dev/null 2>&1; then
                root_ssh_dir="/var/root/.ssh"
                root_builder_key="$root_ssh_dir/opencode-linux-builder"
                root_known_hosts="$root_ssh_dir/known_hosts"

                if ! sudo test -f "$root_builder_key"; then
                  sudo install -d -m 700 "$root_ssh_dir"
                  sudo install -m 600 "$builder_ssh_key" "$root_builder_key"
                fi

                if ! sudo test -f "$root_known_hosts" || ! sudo grep -Fq '[127.0.0.1]:31022 ' "$root_known_hosts"; then
                  tmp_known_hosts="$(mktemp)"
                  ssh-keyscan -p 31022 127.0.0.1 2>/dev/null | grep '^\[127.0.0.1\]:31022 ' > "$tmp_known_hosts"
                  sudo touch "$root_known_hosts"
                  sudo chmod 600 "$root_known_hosts"
                  while IFS= read -r key_line; do
                    [ -z "$key_line" ] && continue
                    sudo grep -Fqx "$key_line" "$root_known_hosts" || printf '%s\n' "$key_line" | sudo tee -a "$root_known_hosts" >/dev/null
                  done < "$tmp_known_hosts"
                  rm -f "$tmp_known_hosts"
                fi

                builders="ssh://builder@127.0.0.1:31022 ${guestSystem} $root_builder_key 4 1 benchmark,big-parallel,nixos-test"
                break
              fi
              sleep 1
            done
          fi

          if [ -z "$builders" ]; then
            cat >&2 <<'EOF'
    Failed to configure a Linux builder on Darwin.

    Run this once and then retry:
      (cd /tmp/opencode-linux-builder && nix run nixpkgs#darwin.linux-builder)

    Or provide one explicitly for this run:
      OPENCODE_VM_BUILDERS='ssh-ng://builder@linux-host aarch64-linux - 4 1' nix run .
    EOF
            echo "If you attempted auto-bootstrap, inspect /tmp/opencode-linux-builder/bootstrap.log" >&2
            exit 1
          fi

          nix_build_args+=(--builders "$builders")
        fi

        mkdir -p "$runtime_dir"

        replace_with_link() {
          local src="$1"
          local dst="$2"
          rm -rf "$dst"
          ln -s "$src" "$dst"
        }

        replace_with_dir() {
          local dst="$1"
          rm -rf "$dst"
          mkdir -p "$dst"
        }

        replace_with_link "$PWD" "$state_dir/workdir"

        if [ -d "$HOME/.config/opencode" ]; then
          replace_with_link "$HOME/.config/opencode" "$state_dir/config-opencode"
        else
          replace_with_dir "$state_dir/config-opencode"
        fi

        if [ -d "$HOME/.agents" ]; then
          replace_with_link "$HOME/.agents" "$state_dir/agents"
        else
          replace_with_dir "$state_dir/agents"
        fi

        mkdir -p "$HOME/.local/share/opencode"
        replace_with_link "$HOME/.local/share/opencode" "$state_dir/data-opencode"

        : > "$port_file"
        : > "$runtime_dir/args"
        rm -f "$verbose_file"
        if [ "$vm_verbose" -eq 1 ]; then
          : > "$verbose_file"
        fi

        pending_port_value=0
        selected_port=""
        for arg in "''${forwarded_args[@]}"; do
          printf '%s\n' "$arg" >> "$runtime_dir/args"

          if [ "$pending_port_value" -eq 1 ]; then
            selected_port="$arg"
            pending_port_value=0
            continue
          fi

          case "$arg" in
            --port)
              pending_port_value=1
              ;;
            --port=*)
              selected_port="''${arg#--port=}"
              ;;
          esac
        done

        case "$selected_port" in
          ""|*[!0-9]*)
            ;;
          *)
            printf '%s\n' "$selected_port" > "$port_file"
            ;;
        esac

        vm_attr=".#packages.${hostSystem}.vm-''${vm_size}"
        vm_out="$(nix path-info --accept-flake-config --option warn-dirty false "''${nix_build_args[@]}" "$vm_attr" 2>/dev/null | tail -n 1 || true)"
        if [ -z "$vm_out" ]; then
          vm_out="$(nix build --accept-flake-config --log-format bar --option warn-dirty false "''${nix_build_args[@]}" "$vm_attr" --print-out-paths --no-link | tail -n 1)"
        fi
        echo "info: starting OpenCode VM (size=$vm_size)" >&2
        cd "$state_dir"
        exec "$vm_out/bin/microvm-run"
  '';
}
