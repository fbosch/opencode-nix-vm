set -euo pipefail

host_system="$1"
guest_system="$2"
darwin_builder_script="$3"
shift 3

state_dir="/tmp/opencode-microvm"
runtime_dir="$state_dir/runtime"
port_file="$runtime_dir/port"
verbose_file="$runtime_dir/verbose"
nix_build_args=()
vm_verbose=0
forwarded_args=()

parse_args() {
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
}

configure_darwin_builder() {
  case "$host_system" in
    *-darwin) ;;
    *) return ;;
  esac

  local builders
  builders="$("$darwin_builder_script" "$guest_system")"

  nix_build_args+=(--builders "$builders")
}

mkdir -p "$runtime_dir"

replace_with_link() {
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
  ln -s "$src" "$dst"
}

replace_with_dir() {
  local dst="$1"
  rm -rf "$dst"
  mkdir -p "$dst"
}

prepare_host_state() {
  mkdir -p "$runtime_dir"

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
}

write_runtime_contract() {
  local pending_port_value=0
  local selected_port=""

  : > "$port_file"
  : > "$runtime_dir/args"
  rm -f "$verbose_file"
  if [ "$vm_verbose" -eq 1 ]; then
    : > "$verbose_file"
  fi

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
}

resolve_vm_output() {
  local vm_attr=".#packages.${host_system}.vm"
  local vm_out=""

  echo "info: preparing OpenCode VM" >&2
  vm_out="$(nix path-info --accept-flake-config --option warn-dirty false "${nix_build_args[@]}" "$vm_attr" 2>/dev/null | tail -n 1 || true)"
  if [ -z "$vm_out" ]; then
    vm_out="$(nix build --accept-flake-config --log-format bar --option warn-dirty false "${nix_build_args[@]}" "$vm_attr" --print-out-paths --no-link | tail -n 1)"
  fi

  printf '%s\n' "$vm_out"
}

prepare_runner() {
  local vm_out="$1"
  local runner="$vm_out/bin/microvm-run"

  if [ "$vm_verbose" -eq 0 ]; then
    local patched_runner="$runtime_dir/microvm-run-quiet"

    if [ ! -f "$patched_runner" ] || [ "$runner" -nt "$patched_runner" ]; then
      local runner_contents
      runner_contents="$(<"$runner")"
      printf '%s' "${runner_contents//earlyprintk=ttyS0 /}" > "$patched_runner"
      chmod 700 "$patched_runner"
    fi

    runner="$patched_runner"
  fi

  printf '%s\n' "$runner"
}

main() {
  local vm_out
  local runner

  parse_args "$@"
  configure_darwin_builder
  prepare_host_state
  write_runtime_contract

  vm_out="$(resolve_vm_output)"
  echo "info: starting OpenCode VM" >&2
  cd "$state_dir"

  runner="$(prepare_runner "$vm_out")"
  exec "$runner"
}

main "$@"
