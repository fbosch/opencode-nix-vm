set -euo pipefail

opencode_bin="$1"

host_config="/host-config/opencode"
host_agents="/host-config/agents"
host_data="/host-data/opencode"
host_runtime="/run/opencode-host"

config_dir="$host_data/config"
state_dir="$host_data/state"
cache_dir="$host_data/cache"

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

remove_legacy_hostconfig_link() {
  local path="$1"

  if [ -L "$path" ]; then
    local target
    target="$(readlink "$path" || true)"
    case "$target" in
      /host-config/*)
        rm -f "$path"
        ;;
    esac
  fi
}

copy_if_missing() {
  local dst="$1"
  local src="$2"

  if [ ! -e "$dst" ] && [ -e "$src" ]; then
    cp -aL "$src" "$dst" 2>/dev/null || true
  fi
}

mkdir -p /root/.config /root/.local/share /root/.local/state /root/.cache
mkdir -p "$config_dir" "$state_dir" "$cache_dir"

if [ ! -f "$config_dir/.seeded" ]; then
  cp -aL "$host_config/." "$config_dir/" 2>/dev/null || true
  touch "$config_dir/.seeded"
fi

for name in skills themes agents; do
  remove_legacy_hostconfig_link "$config_dir/$name"
done

copy_if_missing "$config_dir/opencode.json" "$host_config/opencode.json"
copy_if_missing "$config_dir/themes" "$host_config/themes"
copy_if_missing "$config_dir/skills" "$host_config/skills"
copy_if_missing "$config_dir/skills" "$host_agents/skills"
copy_if_missing "$config_dir/agents" "$host_agents/agents"

if [ ! -f "$host_runtime/verbose" ]; then
  printf '\033[2J\033[H'
fi

ensure_symlink "$config_dir" /root/.config/opencode
ensure_symlink "$host_agents" /root/.agents
ensure_symlink "$host_data" /root/.local/share/opencode
ensure_symlink "$state_dir" /root/.local/state/opencode
ensure_symlink "$cache_dir" /root/.cache/opencode

cd /project

if [ -f "$host_runtime/args" ]; then
  mapfile -t OPENCODE_ARGS < "$host_runtime/args"
  "$opencode_bin" "${OPENCODE_ARGS[@]}"
else
  "$opencode_bin"
fi

/run/current-system/sw/bin/poweroff -f || true
exit 0
