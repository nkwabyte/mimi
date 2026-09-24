# Security and Safety Policy

## Core Safety Invariants

`mimi` is designed with strict safety boundaries to prevent accidental or malicious destruction of system and user data. Every file deletion or mutation must strictly satisfy the following invariants:

### 1. Canonical Root Containment
- Every candidate path is canonicalized to its real physical path (`path_canonicalize`) before evaluation.
- All mutations are restricted to three authorized root trees:
  1. `$HOME` (the current user's home directory).
  2. The per-user temporary directory (`$TMPDIR`, resolved under `/private/var/folders/...`).
  3. Explicitly registered roots within targeted category boundaries.
- Traversal components (`..`) are rejected outright during path authorization.
- System roots (`/`, `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/sbin`, `/var`, `/etc`, and `$HOME` itself) are strictly forbidden from being removed or cleared.

### 2. Symlink Safety
- Intermediate path symlinks cannot escape the allowed roots.
- Terminal symlinks are treated strictly: deleting a symlink unlinks the symlink itself and never traverses into or deletes the symlink's target.

### 3. Whitelist Invariants
- Whitelist rules are normalized and canonicalized against the real filesystem.
- If a target or any of its parent directories is whitelisted, the target is protected from modification or deletion.

### 4. Revalidation & TOCTOU Defense
- The filesystem identity (`st_dev` and `st_ino`) is validated prior to mutation. If a path object is swapped or replaced between discovery and removal, the mutation is refused.

### 5. Confirmation and Risk Classification
Operations are classified into four distinct confirmation classes:
- **`safe`**: Regenerable caches and temporary files. Scriptable via `-y` / `--yes`.
- **`moderate`**: Work with rebuild/download costs or system impact (e.g. local Time Machine snapshots, DeviceSupport symbols, old Homebrew versions). Opt-in by default.
- **`risky`**: Operations that may delete configuration or state (e.g., Docker container/volume prune, Mail downloads, Android system images). Requires explicit preflight authorization via `--force-risky <name>`.
- **`irreversible`**: Permanent, non-recoverable actions (e.g. macOS Trash, iOS device backups, orphan file removal). Requires explicit opt-in flags AND `--force-risky <name>`. `--yes` alone will never approve risky or irreversible work.

### 6. Privilege Model
- `mimi` never requires `sudo` or root privileges. It must run exclusively with normal user privileges.

## Reporting a Vulnerability

If you discover a potential security or safety issue (such as an escape from the allowed-root envelope, an unconfirmed deletion vector, or an unhandled symlink attack), please report it responsibly by opening a private security advisory on GitHub or emailing the repository maintainers.
