set -euo pipefail

opencode_bin="$1"

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
  "$opencode_bin" "${OPENCODE_ARGS[@]}"
else
  "$opencode_bin"
fi

/run/current-system/sw/bin/poweroff -f || true
exit 0
