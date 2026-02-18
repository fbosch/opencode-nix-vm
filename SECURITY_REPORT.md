# OpenCode MicroVM Sandbox — Security Audit Report

**Date:** 2026-02-18
**Scope:** Static review of Nix/shell configuration + live probing from inside the guest VM
**Methodology:** Read-only analysis; no code was modified

---

## Executive Summary

The OpenCode MicroVM sandbox provides meaningful isolation by running the AI agent inside a QEMU/KVM guest with 9p-shared filesystems. However, several configuration weaknesses — most critically AppArmor in complain mode and excessive process capabilities — substantially reduce the effective security boundary. An agent operating inside this VM can read host credentials, write persistent files to host-visible directories, and reach host network services.

---

## Findings

### CRITICAL

#### 1. AppArmor in Complain Mode

| | |
|---|---|
| **Location** | `modules/microvm-system.nix:41` |
| **Setting** | `state = "complain"` |
| **Impact** | All AppArmor rules are advisory only. Violations are logged but not blocked. The entire AppArmor policy is effectively inert. |

**Recommendation:** Change to `state = "enforce"`.

---

#### 2. Near-Full Linux Capabilities

| | |
|---|---|
| **Observed** | `CapEff: 000001fffffeffff` |
| **Impact** | The opencode service process holds nearly all capabilities including `CAP_SYS_ADMIN`, `CAP_NET_ADMIN`, `CAP_SYS_PTRACE`, and `CAP_DAC_OVERRIDE`. Combined with complain-mode AppArmor, nothing prevents their use. |

**Recommendation:** Restrict capabilities via systemd:

```nix
serviceConfig = {
  CapabilityBoundingSet = [
    "CAP_CHOWN"
    "CAP_FOWNER"
    "CAP_DAC_OVERRIDE"
    "CAP_SETUID"
    "CAP_SETGID"
  ];
  AmbientCapabilities = [];
};
```

---

#### 3. Host Credentials Readable

| | |
|---|---|
| **File** | `/host-data/opencode/auth.json` |
| **Contents** | OAuth tokens (GitHub Copilot, OpenAI), API keys |
| **Impact** | Any code running in the VM can read and exfiltrate these credentials. |

**Recommendation:**

- Move `auth.json` outside the shared filesystem entirely.
- Or inject credentials via systemd `LoadCredential` / environment variables scoped to the service.
- At minimum, mount the file into a separate read-only share with tighter AppArmor restrictions.

---

### HIGH

#### 4. Writable Host-Visible Filesystem

| | |
|---|---|
| **Path** | `/host-data/opencode/` |
| **Mount** | 9p, read-write |
| **Impact** | Files written here persist on the host at `~/.local/share/opencode/`. An agent can create executable scripts (e.g., in `bin/`) that may later be run by the host user or host-side tooling. |

**Verified:** Successfully created `/host-data/opencode/malicious.sh` (executable) during prior testing.

**Recommendation:**

- Mount as read-only wherever possible.
- If writes are required, restrict to specific subdirectories and deny executable creation:

```apparmor
deny /host-data/opencode/bin/** w,
deny /host-data/opencode/** x,
```

---

#### 5. 9p Mounts Use Implicit `security_model=none`

| | |
|---|---|
| **Affected** | All 9p shares (`workdir`, `opencode-data`, `opencode-config`, `agents-config`, `runtime-args`) |
| **Impact** | No UID/GID remapping between guest and host. Guest root writes files as host root (or the host UID running QEMU). No xattr-based permission translation. |

**Recommendation:** Use `security_model=mapped-xattr` or `mapped-file` for writable shares.

---

#### 6. Virtualization Devices Exposed

| | |
|---|---|
| **Devices** | `/dev/kvm` (0666), `/dev/vhost-net` (0666), `/dev/vhost-vsock` (0666) |
| **Impact** | World-writable access to KVM and vhost devices inside the guest. Could be used for nested virtualization attacks or hypervisor confusion. |

**Recommendation:**

- Do not pass these devices to the guest in the QEMU configuration.
- Or deny access in AppArmor:

```apparmor
deny /dev/kvm rw,
deny /dev/vhost-* rw,
```

---

### MEDIUM

#### 7. Running as Root Inside VM

| | |
|---|---|
| **Observed** | All processes run as UID 0 |
| **Impact** | Reduces defense-in-depth. If AppArmor or any other control fails, there is no secondary user-based restriction. |

**Recommendation:**

```nix
users.users.opencode = {
  isSystemUser = true;
  group = "opencode";
  home = "/home/opencode";
};
serviceConfig.User = "opencode";
serviceConfig.Group = "opencode";
```

---

#### 8. Network Access to Host

| | |
|---|---|
| **Interface** | `enp0s8` — `10.0.2.15/24` (QEMU user-mode) |
| **Host reachable at** | `10.0.2.2` |
| **Impact** | The VM can reach any service listening on the host (SSH, Docker, databases, dev servers). Combined with credential theft, this enables lateral movement. |

**Recommendation:**

- If outbound internet is not needed, disable networking entirely.
- If it is needed, firewall the host gateway:

```nix
networking.firewall = {
  enable = true;
  extraCommands = ''
    iptables -A OUTPUT -d 10.0.2.2 -j DROP
  '';
};
```

Note: `networking.firewall.enable` is currently set to `false` (`modules/microvm-system.nix:22`).

---

#### 9. No Explicit Seccomp Syscall Filter

| | |
|---|---|
| **Observed** | 13 seccomp filters active (inherited from systemd defaults) |
| **Impact** | Unknown which dangerous syscalls are permitted. `mount`, `ptrace`, `kexec_load`, and `init_module` may be available. |

**Recommendation:**

```nix
serviceConfig = {
  SystemCallFilter = [
    "@system-service"
    "~@privileged"
    "~@resources"
    "~@mount"
    "~@module"
  ];
  SystemCallErrorNumber = "EPERM";
};
```

---

#### 10. Config Symlink Manipulation

| | |
|---|---|
| **Location** | `modules/opencode-session.sh:89-93` |
| **Issue** | The session script creates symlinks from writable locations (`/root/.config/opencode`, etc.) to shared mounts. A malicious process could replace these symlinks to point at attacker-controlled paths under `/host-data/opencode/`. |

**Recommendation:** Validate that symlink targets are within expected directories before creating them. Use `realpath` to resolve and check targets.

---

### LOW

#### 11. No Resource Limits

| | |
|---|---|
| **Impact** | No limits on file descriptors, process count, or CPU time. A runaway agent could exhaust VM resources. |

**Recommendation:**

```nix
serviceConfig = {
  LimitNOFILE = 4096;
  LimitNPROC = 256;
  TasksMax = 256;
  MemoryMax = "2G";
};
```

---

#### 12. Launcher Script TOCTOU Risks

| | |
|---|---|
| **Location** | `modules/opencode-launcher.sh:157-171` (`replace_with_link`) |
| **Issue** | Checks and operations on symlinks are not atomic. A race condition could allow symlink substitution between check and use. |

**Recommendation:** Use atomic operations where possible. The `ensure_private_dir` function already checks ownership, but `replace_with_link` does not verify the target is safe.

---

#### 13. Verbose Mode Information Disclosure

| | |
|---|---|
| **Flag** | `--verbose` |
| **Impact** | Exposes QEMU command-line arguments, kernel boot parameters, and hypervisor configuration details that could aid escape research. |

**Recommendation:** Restrict verbose output in production deployments.

---

## Exploit Scenarios

### Scenario A: Credential Exfiltration

```
1. Read /host-data/opencode/auth.json  (OAuth tokens, API keys)
2. Use VM network access to POST credentials to external server
3. Attacker gains access to victim's AI service accounts
```

### Scenario B: Persistent Host-Side Payload

```
1. Write executable script to /host-data/opencode/bin/
2. Script persists on host at ~/.local/share/opencode/bin/
3. If host tooling or user executes files from that path, arbitrary code runs on host
```

### Scenario C: Network Pivot to Host

```
1. Scan host at 10.0.2.2 for open services
2. Use leaked SSH keys or credentials to access host
3. Full host compromise
```

---

## Positive Security Controls

| Control | Status |
|---|---|
| VM-level isolation (QEMU/KVM) | Active |
| `NoNewPrivileges=true` | Active |
| `ProtectKernelTunables=true` | Active |
| `ProtectKernelModules=true` | Active |
| `ProtectControlGroups=true` | Active |
| `RestrictSUIDSGID=true` | Active |
| `LockPersonality=true` | Active |
| `SystemCallArchitectures=native` | Active |
| `PrivateTmp=true` | Active |
| Nix store mounted read-only | Active |
| Host config mounted read-only | Active |
| `UMask=0077` | Active |

---

## Prioritized Remediation

### Immediate (Ship Blockers)

1. Change AppArmor to enforce mode
2. Drop unnecessary capabilities via `CapabilityBoundingSet`
3. Remove or encrypt `auth.json` from shared filesystem
4. Enable guest firewall / block host gateway

### Short-Term

5. Run OpenCode as non-root user inside VM
6. Set 9p security model to `mapped-xattr`
7. Remove virtualization device access (`/dev/kvm`, `/dev/vhost-*`)
8. Make `/host-data/opencode/` subdirectories read-only where possible

### Medium-Term

9. Define explicit seccomp syscall filter
10. Add resource limits (file descriptors, processes, memory)
11. Validate symlink targets in session script
12. Audit all shared mount points for least-privilege access
