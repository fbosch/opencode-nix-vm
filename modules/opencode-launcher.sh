set -euo pipefail
umask 077

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
vm_cores=""
vm_memory_mb=""

normalize_memory_to_mb() {
  local raw="$1"
  local lower
  lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"

  case "$lower" in
    *gib)
      printf '%s\n' $(( ${lower%gib} * 1024 ))
      ;;
    *gb)
      printf '%s\n' $(( ${lower%gb} * 1024 ))
      ;;
    *g)
      printf '%s\n' $(( ${lower%g} * 1024 ))
      ;;
    *mib)
      printf '%s\n' "${lower%mib}"
      ;;
    *mb)
      printf '%s\n' "${lower%mb}"
      ;;
    *m)
      printf '%s\n' "${lower%m}"
      ;;
    *)
      printf '%s\n' "$lower"
      ;;
  esac
}

ensure_private_dir() {
  local dir="$1"

  if [ -L "$dir" ]; then
    echo "error: refusing symlinked path: $dir" >&2
    exit 1
  fi

  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    echo "error: expected directory path: $dir" >&2
    exit 1
  fi

  mkdir -p "$dir"

  if [ ! -O "$dir" ]; then
    echo "error: directory is not owned by current user: $dir" >&2
    exit 1
  fi

  chmod 700 "$dir"
}

parse_args() {
  local pending_cores=0
  local pending_memory=0

  while [ "$#" -gt 0 ]; do
    if [ "$pending_cores" -eq 1 ]; then
      vm_cores="$1"
      pending_cores=0
      shift
      continue
    fi

    if [ "$pending_memory" -eq 1 ]; then
      vm_memory_mb="$(normalize_memory_to_mb "$1")"
      pending_memory=0
      shift
      continue
    fi

    case "$1" in
      --verbose)
        vm_verbose=1
        ;;
      --cores)
        pending_cores=1
        ;;
      --cores=*)
        vm_cores="${1#--cores=}"
        ;;
      --memory)
        pending_memory=1
        ;;
      --memory=*)
        vm_memory_mb="$(normalize_memory_to_mb "${1#--memory=}")"
        ;;
      *)
        forwarded_args+=("$1")
        ;;
    esac
    shift
  done

  if [ "$pending_cores" -eq 1 ] || [ "$pending_memory" -eq 1 ]; then
    echo "error: missing value for --cores or --memory" >&2
    exit 1
  fi

  case "$vm_cores" in
    ""|*[!0-9]*) ;;
    *)
      if [ "$vm_cores" -lt 1 ]; then
        echo "error: --cores must be >= 1" >&2
        exit 1
      fi
      ;;
  esac

  if [ -n "$vm_cores" ] && [[ "$vm_cores" =~ [^0-9] ]]; then
    echo "error: invalid --cores value: $vm_cores" >&2
    exit 1
  fi

  if [ -n "$vm_memory_mb" ] && [[ "$vm_memory_mb" =~ [^0-9] ]]; then
    echo "error: invalid --memory value" >&2
    exit 1
  fi

  if [ -n "$vm_memory_mb" ] && [ "$vm_memory_mb" -lt 256 ]; then
    echo "error: --memory must be at least 256MB" >&2
    exit 1
  fi
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
  ensure_private_dir "$state_dir"
  ensure_private_dir "$runtime_dir"

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
  local runner_contents
  local patch_required=0

  if [ -n "$vm_cores" ] || [ -n "$vm_memory_mb" ]; then
    case "$host_system" in
      *-darwin)
        echo "warning: --cores/--memory are currently supported for Linux qemu runs only" >&2
        ;;
    esac
  fi

  runner_contents="$(<"$runner")"

  if [ "$vm_verbose" -eq 0 ]; then
    runner_contents="${runner_contents//earlyprintk=ttyS0 /}"
    patch_required=1
  fi

  if [ -n "$vm_cores" ]; then
    runner_contents="$(printf '%s' "$runner_contents" | sed -E "s/-smp [0-9]+/-smp ${vm_cores}/")"
    patch_required=1
  fi

  if [ -n "$vm_memory_mb" ]; then
    runner_contents="$(printf '%s' "$runner_contents" | sed -E "s/-m [0-9]+/-m ${vm_memory_mb}/; s/size=[0-9]+M/size=${vm_memory_mb}M/")"
    patch_required=1
  fi

  if [ "$patch_required" -eq 1 ]; then
    local patched_runner="$runtime_dir/microvm-run-patched"
    printf '%s' "$runner_contents" > "$patched_runner"
    chmod 700 "$patched_runner"
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
