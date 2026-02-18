set -euo pipefail

guest_system="$1"

if [ -n "${OPENCODE_VM_BUILDERS:-}" ]; then
  printf '%s\n' "$OPENCODE_VM_BUILDERS"
  exit 0
fi

builders="$(nix config show --json | jq -r '.builders.value // ""')"
if [ -n "$builders" ]; then
  printf '%s\n' "$builders"
  exit 0
fi

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

    printf 'ssh://builder@127.0.0.1:31022 %s %s 4 1 benchmark,big-parallel,nixos-test\n' "$guest_system" "$root_builder_key"
    exit 0
  fi
  sleep 1
done

cat >&2 <<'EOF'
Failed to configure a Linux builder on Darwin.

Run this once and then retry:
  (cd /tmp/opencode-linux-builder && nix run nixpkgs#darwin.linux-builder)

Or provide one explicitly for this run:
  OPENCODE_VM_BUILDERS='ssh-ng://builder@linux-host aarch64-linux - 4 1' nix run .
EOF
echo "If you attempted auto-bootstrap, inspect /tmp/opencode-linux-builder/bootstrap.log" >&2
exit 1
