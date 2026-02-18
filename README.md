# OpenCode MicroVM Launcher

This project gives you one command to run OpenCode inside a sandboxed NixOS microVM on both Linux and macOS hosts.

## What it does

- Uses `microvm.nix` with host-based hypervisor selection:
  - Linux hosts: `qemu`
  - Darwin hosts: `vfkit`
- Starts OpenCode automatically inside the VM.
- Mounts your current working directory into the guest at `/root/project`.
- Exposes your global OpenCode config and agent config to the guest:
  - `~/.config/opencode` (read-only)
  - `~/.agents` (read-only)
- Reuses host OpenCode data/auth at `~/.local/share/opencode` (read-write).
- Port forwarding behavior:
  - Linux (`qemu`): dynamic host forwarding when `--port` is passed
  - Darwin (`vfkit`): no automatic host port forwarding

## Usage

From the directory you want OpenCode to work on:

```bash
nix run .
```

This boots the VM and drops directly into OpenCode in `/root/project`.
When you exit OpenCode, the VM powers off automatically.

### Pass OpenCode arguments

Arguments after `--` are passed to OpenCode inside the VM.

```bash
nix run . -- run "summarize this repository"
```

### About `--port`

On Linux hosts, forwarding is enabled dynamically only when a numeric `--port` is passed.
On Darwin hosts (`vfkit`), this launcher currently does not configure host port forwarding.

```bash
nix run . -- web --port 4096 --hostname 0.0.0.0
```

On Linux, open `http://localhost:<port>` on the host.

If you do not pass `--port`, OpenCode can still run normally in the VM.
On Linux, host-to-guest web/serve access is not forwarded without `--port`.

## Notes

- The launcher stores runtime links/args under `/tmp/opencode-microvm` on the host (no project-local state directory).
- If `~/.config/opencode` or `~/.agents` do not exist, empty fallback directories are used.
- The VM is isolated, while only selected host paths are shared in.
- On Darwin hosts, a Linux builder is required because the guest is NixOS (`*-linux`).

## Darwin builder notes

On macOS, this project automatically starts a local `nixpkgs#darwin.linux-builder` in the background when no Linux builder is configured.
Builder state lives in `/tmp/opencode-linux-builder`, so project directories stay clean.

Typical setup is to add a remote Linux builder in your Nix config and retry:

```bash
nix run .
```

You can also provide a builder just for one run:

```bash
OPENCODE_VM_BUILDERS='ssh-ng://builder@linux-host aarch64-linux - 4 1' nix run .
```

On Linux hosts, no remote builder is used; native host builds are used by default.
