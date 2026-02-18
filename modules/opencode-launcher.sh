set -euo pipefail

host_system="$1"
guest_system="$2"
shift 2

state_dir="/tmp/opencode-microvm"
runtime_dir="$state_dir/runtime"
port_file="$runtime_dir/port"
verbose_file="$runtime_dir/verbose"
nix_build_args=()
vm_verbose=0
forwarded_args=()
spinner_pid=""
spinner_message=""

start_spinner() {
  if [ "$vm_verbose" -eq 1 ] || [ ! -t 2 ]; then
    return
  fi

  spinner_message="$1"
  (
    local frames=("-" "\\" "|" "/")
    local i=0
    while :; do
      printf "\r%s %s" "$spinner_message" "${frames[i % 4]}" >&2
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  spinner_pid=$!
}

stop_spinner() {
  if [ -z "$spinner_pid" ]; then
    return
  fi

  local status_text="$1"
  kill "$spinner_pid" >/dev/null 2>&1 || true
  wait "$spinner_pid" 2>/dev/null || true
  spinner_pid=""
  printf "\r%s %s\n" "$spinner_message" "$status_text" >&2
}

cleanup_spinner() {
  if [ -n "$spinner_pid" ]; then
    stop_spinner "failed"
  fi
}

trap cleanup_spinner EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --verbose)
      vm_verbose=1
      ;;
    *)
      forwarded_args+=("$1")
      ;;
  esac
  shift
done

# shellcheck disable=SC2194
case "$host_system" in
  *-darwin)
    builders=""

    if [ -n "${OPENCODE_VM_BUILDERS:-}" ]; then
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

      if ! ssh "${builder_ssh_opts[@]}" -p 31022 builder@127.0.0.1 true >/dev/null 2>&1; then
        echo "info: starting local darwin linux-builder in background" >&2
        (
          cd "$builder_state_dir"
          nohup nix run --accept-flake-config nixpkgs#darwin.linux-builder </dev/null >"$builder_log" 2>&1 &
        )
      fi

      for _ in $(seq 1 120); do
        if [ -f "$builder_ssh_key" ] && ssh "${builder_ssh_opts[@]}" -p 31022 builder@127.0.0.1 true >/dev/null 2>&1; then
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

          builders="ssh://builder@127.0.0.1:31022 $guest_system $root_builder_key 4 1 benchmark,big-parallel,nixos-test"
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
    ;;
esac

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
for arg in "${forwarded_args[@]}"; do
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
      selected_port="${arg#--port=}"
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

vm_attr=".#packages.${host_system}.vm"
start_spinner "info: preparing OpenCode VM"
vm_out="$(nix path-info --accept-flake-config --option warn-dirty false "${nix_build_args[@]}" "$vm_attr" 2>/dev/null | tail -n 1 || true)"
if [ -z "$vm_out" ]; then
  vm_out="$(nix build --accept-flake-config --log-format bar --option warn-dirty false "${nix_build_args[@]}" "$vm_attr" --print-out-paths --no-link | tail -n 1)"
fi
stop_spinner "ready"
echo "info: starting OpenCode VM" >&2
cd "$state_dir"

runner="$vm_out/bin/microvm-run"
if [ "$vm_verbose" -eq 0 ]; then
  patched_runner="$runtime_dir/microvm-run-quiet"
  runner_contents="$(<"$runner")"
  printf '%s' "${runner_contents//earlyprintk=ttyS0 /}" > "$patched_runner"
  chmod 700 "$patched_runner"
  runner="$patched_runner"
fi

trap - EXIT
exec "$runner"
