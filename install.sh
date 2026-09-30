#!/usr/bin/env bash
# Bootstrap or test a machine configuration from a Nix flake repo.
# Run with --help for usage. Written for bash 3.2 (macOS's /bin/bash). Safe to re-run.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install.sh [options] [darwin|nixos|home-manager] [config]

Arguments:
  config          Name of the machine/user configuration in flake.nix — the part
                  after the relevant output name. Examples:
                    darwinConfigurations.macbook         -> macbook
                    nixosConfigurations.desktop          -> desktop
                    homeConfigurations."michael@laptop" -> michael@laptop
                  So `install.sh nixos desktop` selects
                  nixosConfigurations.desktop. The method may be omitted when it
                  matches this machine, e.g. `install.sh desktop` on NixOS.
                  If config is omitted, the only matching config is selected
                  automatically, or a menu is shown when there are several.

Options:
  --repo <repo>   Flake repo to clone: owner/repo, host/owner/repo or a URL.
                  Not needed when running from inside a clone.
                  (env: NIX_HOSTS_REPO; host defaults to github.com)
  --branch <name> Branch or tag to use (env: NIX_HOSTS_BRANCH). For an existing
                  clone, switch to it if needed (only when the worktree is clean).
                  Defaults to the repository's default branch (remote HEAD).
  --dir <path>    Where to clone it (env: NIX_HOSTS_DIR;
                  default: ~/<host>/<owner>/<repo>)
  --auth <how>    How to authenticate the clone:
                    auto   try without signing in, ask if that fails (default)
                    token  temporary read-only token (guided on GitHub)
                    ssh    use an SSH key already added to your account
                    existing  plain git clone with your own git credential setup
                  Existing logins are left untouched. Bootstrap credentials are
                  not kept after cloning.
  --nix-install <mode>
                  Nix installation mode when Nix is missing:
                    auto        prefer multi-user; ask before a single-user
                                fallback on Linux (default)
                    multi-user  require the recommended daemon installation
                    single-user require a single-user install (Linux only)
                  (env: NIX_INSTALL_MODE)
  --write-lock-file
                  Allow creating/updating flake.lock before evaluation. Without
                  this flag, the script asks before writing when a lock is missing
                  or stale. --dry-run never writes a lock file.
  --dry-run       Do not activate or persist repo/config changes: list setup steps
                  and evaluate/build plans without writing flake.lock
  --build         Build the config without activating it (result -> <repo>/result)
  --vm            Build a QEMU VM from a NixOS config (needs Linux or a Linux builder)
  -h, --help      Show this help

Without --dry-run/--build/--vm: install Nix if needed, clone the repo, and
activate the config.

Method defaults: macOS -> darwin, NixOS -> nixos, other Linux -> home-manager.
                 --vm implies nixos. The method can be omitted: `install.sh macbook`.
Examples:
  # Full invocation: repo, branch/tag, destination, auth method, platform method and config
  curl -fsSL https://raw.githubusercontent.com/<owner>/nix-flake-bootstrap/v0.1.0/install.sh | bash -s -- \
    --repo owner/repo \
    --branch testing \
    --dir "$HOME/src/nix-hosts" \
    --auth token \
    --nix-install auto \
    --write-lock-file \
    nixos my-desktop

  curl -fsSL https://raw.githubusercontent.com/<owner>/nix-flake-bootstrap/v0.1.0/install.sh | bash -s -- --repo owner/repo
  curl -fsSL https://raw.githubusercontent.com/<owner>/nix-flake-bootstrap/v0.1.0/install.sh | bash -s -- --repo owner/repo --branch testing
  curl -fsSL https://raw.githubusercontent.com/<owner>/nix-flake-bootstrap/v0.1.0/install.sh | bash -s -- --repo owner/repo --auth ssh
  ./install.sh --build home-manager my-laptop
  ./install.sh --dry-run nixos my-desktop       # evaluate a Linux config from a Mac
  ./install.sh --vm my-desktop
USAGE
}

log()     { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
dry()     { printf '\n\033[1;33m[dry-run]\033[0m %s\n' "$*"; }
warn()    { printf '\n\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
fail()    { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }
confirm() { local a; read -rp "$1 [y/N] " a < /dev/tty; [[ "$a" == [yY]* ]]; }

NIX_DAEMON_SH="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
NIX_USER_SH="$HOME/.nix-profile/etc/profile.d/nix.sh"
load_nix() {
  local profile
  for profile in "$NIX_DAEMON_SH" "$NIX_USER_SH"; do
    if ! command -v nix >/dev/null 2>&1 && [[ -e "$profile" ]]; then
      set +u
      # shellcheck disable=SC1090
      . "$profile"
      set -u
    fi
  done
}

# Enable flakes only for commands launched by this script. The user's persistent
# nix.conf is intentionally left alone; their flake can configure this declaratively.
NIX_FLAGS=(--extra-experimental-features "nix-command flakes")
NIX_FEATURE_CONFIG="extra-experimental-features = nix-command flakes"
nixf() { nix "${NIX_FLAGS[@]}" "$@"; }

nix_config_with_features() {
  if [[ -n "${NIX_CONFIG:-}" ]]; then
    printf '%s\n%s' "$NIX_CONFIG" "$NIX_FEATURE_CONFIG"
  else
    printf '%s' "$NIX_FEATURE_CONFIG"
  fi
}

# Lock flags are chosen after the repository is ready. Keep them after the Nix
# subcommand because they are flake-related options of commands such as build/eval.
FLAKE_LOCK_FLAGS=()
nix_flake() {
  local command="$1"
  shift
  nix "${NIX_FLAGS[@]}" "$command" "${FLAKE_LOCK_FLAGS[@]}" "$@"
}

# Tools that are only needed temporarily come from the Nix store, not a profile,
# so nothing gets installed (`nix-collect-garbage` removes them later).
nix_tool() { printf '%s/bin/%s' "$(nixf build --no-link --print-out-paths "nixpkgs#$1" | head -n1)" "$1"; }

ensure_git() {
  # Use the system git, except macOS's /usr/bin/git stub, which pops up the
  # Xcode installer when the Command Line Tools are missing
  if command -v git >/dev/null 2>&1 && { [[ "$OS" != "Darwin" ]] || xcode-select -p >/dev/null 2>&1; }; then
    return 0
  fi
  command -v nix >/dev/null 2>&1 || return 1
  log "Fetching a temporary git from nixpkgs..."
  local git_bin
  git_bin="$(nix_tool git)" || return 1
  PATH="$(dirname "$git_bin"):$PATH"
  export PATH
}

ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  command -v nix >/dev/null 2>&1 || return 1
  log "Fetching a temporary curl from nixpkgs..."
  local curl_bin
  curl_bin="$(nix_tool curl)" || return 1
  PATH="$(dirname "$curl_bin"):$PATH"
  export PATH
}

open_url() {
  # Always print the URL as well, so this remains usable over SSH/headless.
  local url="$1"
  printf '\n  %s\n' "$url" > /dev/tty
  if [[ "$OS" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

# Scratch space for temporary bootstrap state. It's removed
# on exit, along with any empty folders made for a clone that didn't finish.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-sh.XXXXXX")"
CREATED_TOP=""
CLONED=0
# Set only while a guided GitHub bootstrap token is live. It is kept in memory,
# never written to a file, and cleared immediately after clone/revocation.
ACTIVE_GITHUB_TOKEN=""
cleanup() {
  # Never let xtrace expose a live token during best-effort exit cleanup.
  set +x 2>/dev/null || true
  if [[ -n "${ACTIVE_GITHUB_TOKEN:-}" ]] && command -v revoke_active_github_token >/dev/null 2>&1; then
    revoke_active_github_token >/dev/null 2>&1 || true
  fi
  ACTIVE_GITHUB_TOKEN=""
  rm -rf "$WORK"
  if [[ $CLONED -eq 0 && -n "$CREATED_TOP" && -d "$CREATED_TOP" ]]; then
    find "$CREATED_TOP" -depth -type d -empty -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# 0. Arguments
# ---------------------------------------------------------------------------
MODE="switch"
AUTH="auto"
NIX_INSTALL_MODE="${NIX_INSTALL_MODE:-auto}"
WRITE_LOCK_FILE=0
REPO="${NIX_HOSTS_REPO:-}"
BRANCH="${NIX_HOSTS_BRANCH:-}"
DIR="${NIX_HOSTS_DIR:-}"
POS1=""
POS2=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run" ;;
    --build)   MODE="build" ;;
    --vm)      MODE="vm" ;;
    --write-lock-file) WRITE_LOCK_FILE=1 ;;
    --repo)    [[ $# -ge 2 ]] || fail "--repo needs a value."; REPO="$2"; shift ;;
    --repo=*)  REPO="${1#--repo=}" ;;
    --branch)  [[ $# -ge 2 ]] || fail "--branch needs a value."; BRANCH="$2"; shift ;;
    --branch=*) BRANCH="${1#--branch=}" ;;
    --dir)     [[ $# -ge 2 ]] || fail "--dir needs a value."; DIR="$2"; shift ;;
    --dir=*)   DIR="${1#--dir=}" ;;
    --auth)    [[ $# -ge 2 ]] || fail "--auth needs a value."; AUTH="$2"; shift ;;
    --auth=*)  AUTH="${1#--auth=}" ;;
    --nix-install) [[ $# -ge 2 ]] || fail "--nix-install needs a value."; NIX_INSTALL_MODE="$2"; shift ;;
    --nix-install=*) NIX_INSTALL_MODE="${1#--nix-install=}" ;;
    -h|--help) usage; exit 0 ;;
    -*)        usage >&2; fail "Unknown option: $1" ;;
    *)
      if   [[ -z "$POS1" ]]; then POS1="$1"
      elif [[ -z "$POS2" ]]; then POS2="$1"
      else usage >&2; fail "Too many arguments."
      fi ;;
  esac
  shift
done

case "$AUTH" in
  auto|token|ssh|existing) ;;
  *) fail "Unknown --auth '$AUTH' (expected auto, token, ssh or existing)." ;;
esac

case "$NIX_INSTALL_MODE" in
  auto|multi-user|single-user) ;;
  *) fail "Unknown --nix-install '$NIX_INSTALL_MODE' (expected auto, multi-user or single-user)." ;;
esac

case "$POS1" in
  darwin|nixos|home-manager) METHOD="$POS1"; CONFIG="$POS2" ;;
  *)
    [[ -z "$POS2" ]] || fail "Unknown method '$POS1' (expected darwin, nixos or home-manager)."
    METHOD=""; CONFIG="$POS1" ;;
esac

OS="$(uname -s)"
[[ $EUID -ne 0 ]] || fail "Run as your normal user, not root (sudo will be requested when needed)."

# ---------------------------------------------------------------------------
# 1. Where is the flake? (this script's clone, an existing clone, or a new one)
# ---------------------------------------------------------------------------
# Accepts owner/repo, host/owner/repo, https://host/owner/repo(.git), git@host:owner/repo
HOST=""; OWNER=""; NAME=""
if [[ -n "$REPO" ]]; then
  r="${REPO#https://}"; r="${r#http://}"; r="${r#ssh://}"; r="${r#git@}"
  r="${r%/}"; r="${r%.git}"; r="${r/://}"
  IFS=/ read -r p1 p2 p3 extra <<< "$r"
  if [[ -n "${p3:-}" ]]; then HOST="$p1"; OWNER="$p2"; NAME="$p3"
  else                        HOST="github.com"; OWNER="${p1:-}"; NAME="${p2:-}"
  fi
  [[ -n "$OWNER" && -n "$NAME" && -z "${extra:-}" ]] \
    || fail "Can't parse --repo '$REPO' (expected owner/repo, host/owner/repo or a URL)."
  REPO="$HOST/$OWNER/$NAME"
fi

SCRIPT_PATH="${BASH_SOURCE[0]:-}"
EXISTING_GIT_REPO=0
if [[ -n "$SCRIPT_PATH" && -e "$(dirname "$SCRIPT_PATH")/.git" ]]; then
  # When the script is run from a clone, use that clone even if the currently
  # checked-out branch does not contain flake.nix yet. --branch may fix that.
  DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  NEED_CLONE=0
  EXISTING_GIT_REPO=1
elif [[ -n "$SCRIPT_PATH" && -f "$(dirname "$SCRIPT_PATH")/flake.nix" ]]; then
  DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
  NEED_CLONE=0
else
  if [[ -z "$DIR" ]]; then
    [[ -n "$REPO" ]] || { usage >&2; fail "Tell me which repo to use with --repo owner/repo."; }
    DIR="$HOME/$HOST/$OWNER/$NAME"
  fi
  if [[ -e "$DIR/.git" ]]; then
    NEED_CLONE=0
    EXISTING_GIT_REPO=1
  elif [[ -f "$DIR/flake.nix" ]]; then
    NEED_CLONE=0
  elif [[ -e "$DIR" ]]; then
    fail "$DIR exists but is not a Git clone and has no flake.nix. Move it or pick another --dir."
  else
    [[ -n "$REPO" ]] || fail "No flake in $DIR. Pass --repo owner/repo so it can be cloned."
    NEED_CLONE=1
  fi
fi


if [[ $EXISTING_GIT_REPO -eq 1 && ! -f "$DIR/flake.nix" && -z "$BRANCH" ]]; then
  fail "$DIR is already a Git clone, but its current checkout has no flake.nix. Pass --branch <name> to switch to the branch that contains it."
fi

CLONE_BRANCH_ARGS=()
if [[ -n "$BRANCH" ]]; then
  CLONE_BRANCH_ARGS=(--branch "$BRANCH")
fi

# ---------------------------------------------------------------------------
# 2. Method
# ---------------------------------------------------------------------------
if [[ -z "$METHOD" ]]; then
  if   [[ "$MODE" == "vm" ]];     then METHOD="nixos"
  elif [[ "$OS" == "Darwin" ]];   then METHOD="darwin"
  elif [[ -e /etc/NIXOS ]];       then METHOD="nixos"
  else                                 METHOD="home-manager"
  fi
fi

case "$METHOD" in
  darwin)       ATTR="darwinConfigurations"; OUTPUT="system" ;;
  nixos)        ATTR="nixosConfigurations";  OUTPUT="config.system.build.toplevel" ;;
  home-manager) ATTR="homeConfigurations";   OUTPUT="activationPackage" ;;
esac

if [[ "$MODE" == "vm" ]]; then
  [[ "$METHOD" == "nixos" ]] || fail "--vm only works with NixOS configs."
  OUTPUT="config.system.build.vm"
fi

# Only activation is tied to the current OS; building and evaluating are not
if [[ "$MODE" == "switch" ]]; then
  if [[ "$METHOD" == "darwin" && "$OS" != "Darwin" ]]; then
    fail "nix-darwin configs can only be activated on macOS (try --dry-run)."
  fi
  if [[ "$METHOD" == "nixos" && ! -e /etc/NIXOS ]]; then
    fail "NixOS configs can only be activated on NixOS (try --build, --vm or --dry-run)."
  fi
fi
log "Method: $METHOD   Mode: $MODE   Flake: $DIR"

# ---------------------------------------------------------------------------
# 3. Nix
# ---------------------------------------------------------------------------
BRANCH_PLAN=""
[[ -z "$BRANCH" ]] || BRANCH_PLAN=" at branch/tag '$BRANCH'"
if [[ "$AUTH" == "auto" ]]; then
  CLONE_PLAN="Would try cloning $REPO$BRANCH_PLAN into $DIR without signing in, and ask how to sign in if that fails"
else
  CLONE_PLAN="Would clone $REPO$BRANCH_PLAN into $DIR using --auth $AUTH"
fi

linux_systemd_running() {
  [[ -d /run/systemd/system ]]
}

linux_selinux_disabled() {
  local state=""
  if command -v getenforce >/dev/null 2>&1; then
    state="$(getenforce 2>/dev/null || true)"
    [[ "$state" == "Disabled" ]]
    return
  fi
  # If the SELinux filesystem is mounted, treat SELinux as enabled/unknown and
  # therefore ineligible for automatic multi-user installation.
  [[ ! -e /sys/fs/selinux/enforce ]]
}

linux_multi_user_reason() {
  if ! linux_systemd_running; then
    printf '%s' 'systemd is not running'
    return 1
  fi
  if ! linux_selinux_disabled; then
    printf '%s' 'SELinux is enabled or could not be confirmed disabled'
    return 1
  fi
  return 0
}

choose_nix_install_mode() {
  local reason=""
  case "$OS" in
    Darwin)
      [[ "$NIX_INSTALL_MODE" != "single-user" ]] \
        || fail "--nix-install single-user is not supported on macOS."
      SELECTED_NIX_INSTALL_MODE="multi-user"
      ;;
    Linux)
      reason="$(linux_multi_user_reason 2>/dev/null || true)"
      case "$NIX_INSTALL_MODE" in
        multi-user)
          [[ -z "$reason" ]] \
            || fail "Multi-user Nix installation is not supported on this Linux host: $reason."
          SELECTED_NIX_INSTALL_MODE="multi-user"
          ;;
        single-user)
          SELECTED_NIX_INSTALL_MODE="single-user"
          ;;
        auto)
          if [[ -z "$reason" ]]; then
            SELECTED_NIX_INSTALL_MODE="multi-user"
          elif [[ "$MODE" == "dry-run" ]]; then
            SELECTED_NIX_INSTALL_MODE="ask-single-user"
            NIX_INSTALL_FALLBACK_REASON="$reason"
          else
            warn "The recommended multi-user Nix installation is not supported here: $reason."
            confirm "Use Nix's less-isolated single-user installation instead?" \
              || fail "Nix was not installed. Re-run with --nix-install single-user if you want that fallback."
            SELECTED_NIX_INSTALL_MODE="single-user"
          fi
          ;;
      esac
      ;;
    *)
      fail "Automatic Nix installation is only supported on macOS and Linux (detected: $OS)."
      ;;
  esac
}

install_nix() {
  choose_nix_install_mode
  if [[ "$MODE" == "dry-run" ]]; then
    if [[ "$SELECTED_NIX_INSTALL_MODE" == "ask-single-user" ]]; then
      dry "Multi-user Nix would not be supported ($NIX_INSTALL_FALLBACK_REASON); a real run would ask before using single-user Nix"
    else
      dry "Would install Nix ($SELECTED_NIX_INSTALL_MODE) from https://nixos.org/nix/install"
    fi
    return 0
  fi

  command -v curl >/dev/null 2>&1 \
    || fail "curl is required to install Nix but was not found."
  case "$SELECTED_NIX_INSTALL_MODE" in
    multi-user)
      log "Installing Nix (multi-user; you'll be asked for your password)..."
      curl --disable --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        https://nixos.org/nix/install | sh -s -- --daemon --yes
      ;;
    single-user)
      log "Installing Nix (single-user; less isolated than multi-user)..."
      curl --disable --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        https://nixos.org/nix/install | sh -s -- --no-daemon --yes
      ;;
  esac
}

if ! command -v nix >/dev/null 2>&1 && [[ ! -e "$NIX_DAEMON_SH" && ! -e "$NIX_USER_SH" ]]; then
  install_nix
fi

load_nix

if ! command -v nix >/dev/null 2>&1; then
  if [[ "$MODE" == "dry-run" ]]; then
    if [[ $NEED_CLONE -eq 1 ]]; then
      dry "$CLONE_PLAN"
    elif [[ $EXISTING_GIT_REPO -eq 1 && -n "$BRANCH" ]]; then
      dry "Would reuse $DIR and switch it to branch/tag '$BRANCH' if a switch is needed and the worktree is clean"
    fi
    dry "Would then use process-scoped flake support and set up the $METHOD config."
    dry "Stopping here: nothing can be evaluated before Nix is installed."
    exit 0
  fi
  fail "nix not found on PATH after installation. Open a new terminal and re-run."
fi

# ---------------------------------------------------------------------------
# 4. Clone
#    Tries an anonymous HTTPS clone first and only asks how to sign in if that
#    fails. Existing Git credential helpers and SSH keys are never modified, and
#    bootstrap credentials are not kept after cloning.
# ---------------------------------------------------------------------------
clone_anonymous() {
  # `credential.helper=` clears your configured helpers for this command, so
  # none of them is asked for (or can store) credentials
  local err
  if err="$(env -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_CONFIG_COUNT \
              GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
              git -c credential.helper= clone --quiet "${CLONE_BRANCH_ARGS[@]}" "https://$REPO.git" "$DIR" 2>&1)"; then
    return 0
  fi
  log "Couldn't clone without signing in (${err##*$'\n'})"
  return 1
}

git_clone_with_token() {
  local user="$1" token="$2"

  # Feed the token to the one-off credential helper through an anonymous pipe
  # (fd 9), not argv, the environment, Git config, or a file. Normal/global Git
  # config is disabled so URL rewrites or configured helpers cannot redirect or
  # capture the bootstrap credential.
  # shellcheck disable=SC2016
  env -u GIT_ASKPASS -u SSH_ASKPASS -u GIT_CONFIG_COUNT -u GIT_SSL_NO_VERIFY \
      -u GIT_TRACE -u GIT_TRACE_PACKET -u GIT_TRACE_CURL -u GIT_TRACE_CURL_NO_DATA \
      -u GIT_CURL_VERBOSE -u GIT_TRACE2 -u GIT_TRACE2_EVENT -u GIT_TRACE2_PERF \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      GIT_USER="$user" GIT_TERMINAL_PROMPT=0 git \
        -c credential.helper= \
        -c 'credential.helper=!f() { test "$1" = get || return 0; IFS= read -r password <&9 || return 1; printf "username=%s\\npassword=%s\\n" "$GIT_USER" "$password"; }; f' \
        clone --quiet "${CLONE_BRANCH_ARGS[@]}" "https://$REPO.git" "$DIR" \
        9< <(printf '%s\n' "$token")
}

github_token_url() {
  # GitHub can pre-fill the owner, expiry and permissions, but not the individual
  # repository selection. GitHub owner names contain only URL-safe characters.
  printf '%s' "https://github.com/settings/personal-access-tokens/new?name=Machine+bootstrap&description=Temporary+read-only+token+for+machine+bootstrap&target_name=$OWNER&expires_in=1&contents=read"
}

revoke_active_github_token() {
  [[ -n "${ACTIVE_GITHUB_TOKEN:-}" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 1

  local status
  # --disable ignores ~/.curlrc. The revocation endpoint must be unauthenticated;
  # the credential is sent only in the JSON request body over stdin, never argv.
  if status="$(
    printf '{"credentials":["%s"]}\n' "$ACTIVE_GITHUB_TOKEN" | \
      curl --disable --silent --show-error --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 10 \
        --request POST \
        --header 'Accept: application/vnd.github+json' \
        --header 'Content-Type: application/json' \
        --output /dev/null --write-out '%{http_code}' \
        --data-binary @- \
        https://api.github.com/credentials/revoke
  )"; then
    [[ "$status" == "202" ]]
  else
    return 1
  fi
}

clone_github_token() {
  local token="" url clone_ok=0 had_xtrace=0

  cat > /dev/tty <<EXPLAIN

Creating a temporary read-only token for $OWNER/$NAME.
GitHub will pre-fill:
  - Resource owner: $OWNER
  - Expiration: 1 day
  - Contents: Read-only

In GitHub, you only need to:
  1. Under Repository access, choose "Only select repositories".
  2. Select only "$NAME".
  3. Generate the token and copy it.

Opening GitHub (the URL is also printed below)...
EXPLAIN

  url="$(github_token_url)"
  open_url "$url"

  # Fetching curl before reading the token avoids extending the credential's live
  # window. If unavailable, the one-day expiry still bounds the residual risk.
  if ! ensure_curl; then
    warn "curl is unavailable, so this token cannot be revoked automatically; it will still expire within one day."
  fi

  # A caller may run the installer with bash -x. Disable tracing before the secret
  # is entered and do not re-enable it until the token has been cleared.
  case "$-" in *x*) had_xtrace=1; set +x ;; esac

  printf '\nPaste the generated token (input hidden): ' > /dev/tty
  read -rs token < /dev/tty
  printf '\n' > /dev/tty
  if [[ -z "$token" ]]; then
    [[ $had_xtrace -eq 0 ]] || set -x
    return 1
  fi

  # The guided GitHub path intentionally accepts only fine-grained PATs. Do not
  # silently accept a broader classic PAT when this restricted flow was chosen.
  if [[ "$token" != github_pat_* ]]; then
    token=""
    warn "That does not look like a fine-grained GitHub token (expected github_pat_...)."
    [[ $had_xtrace -eq 0 ]] || set -x
    return 1
  fi

  ACTIVE_GITHUB_TOKEN="$token"
  token=""

  if git_clone_with_token "x-access-token" "$ACTIVE_GITHUB_TOKEN"; then
    clone_ok=1
  fi

  # Revoke immediately after the clone attempt, successful or not. The EXIT trap
  # is only defense in depth for interruptions while ACTIVE_GITHUB_TOKEN is set.
  if revoke_active_github_token; then
    log "Temporary GitHub token revoked."
  else
    warn "Could not confirm revocation of the temporary GitHub token. Its configured expiry is one day; you can also remove it under GitHub Settings > Developer settings > Personal access tokens > Fine-grained tokens."
  fi

  ACTIVE_GITHUB_TOKEN=""
  [[ $had_xtrace -eq 0 ]] || set -x

  if [[ $clone_ok -ne 1 ]]; then
    warn "Clone failed. If $OWNER is an organization, its policy may require approval for fine-grained tokens."
    return 1
  fi
  # Revocation failure does not invalidate a successful clone; report it above and
  # continue with the credential cleared locally.
  return 0
}

clone_generic_token() {
  local user="" token="" had_xtrace=0 clone_ok=0
  read -rp "Username for $HOST: " user < /dev/tty

  case "$-" in *x*) had_xtrace=1; set +x ;; esac
  printf 'Token (input hidden): ' > /dev/tty
  read -rs token < /dev/tty
  printf '\n' > /dev/tty
  if [[ -z "$token" ]]; then
    [[ $had_xtrace -eq 0 ]] || set -x
    return 1
  fi

  if git_clone_with_token "$user" "$token"; then
    clone_ok=1
  fi

  token=""
  [[ $had_xtrace -eq 0 ]] || set -x
  [[ $clone_ok -eq 1 ]]
}

clone_token() {
  if [[ "$HOST" == "github.com" ]]; then
    clone_github_token
  else
    clone_generic_token
  fi
}

clone_ssh() {
  # Uses your SSH keys and ssh config as usual. Known host keys are read from
  # ~/.ssh/known_hosts, but a newly accepted one goes to $WORK (ssh writes to the
  # first file listed), so ~/.ssh/known_hosts isn't changed.
  local ssh_cmd
  ssh_cmd="${GIT_SSH_COMMAND:-$(git config --get core.sshCommand || echo ssh)}"
  GIT_SSH_COMMAND="$ssh_cmd -o 'UserKnownHostsFile=$WORK/known_hosts $HOME/.ssh/known_hosts'" \
    git clone --quiet "${CLONE_BRANCH_ARGS[@]}" "git@$HOST:$OWNER/$NAME.git" "$DIR" < /dev/tty
}

clone_existing() {
  # A normal clone with your own git setup: your credential helpers and prompts
  # behave exactly as they would if you ran git clone yourself
  git clone --quiet "${CLONE_BRANCH_ARGS[@]}" "https://$REPO.git" "$DIR" < /dev/tty
}

normalize_repo_location() {
  # Normalize the common HTTPS/SSH forms we generate or accept so an existing
  # clone can be verified before this script changes its checkout.
  local value="$1"
  value="${value#https://}"
  value="${value#http://}"
  value="${value#ssh://}"
  value="${value#git@}"
  value="${value%/}"
  value="${value%.git}"
  value="${value/://}"
  printf '%s' "$value"
}

prepare_existing_repo() {
  local top dir_real origin normalized_origin current dirty

  ensure_git || fail "git is needed to inspect the existing clone and couldn't be found or fetched."

  top="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "$DIR looks like a Git clone, but Git could not read it."
  top="$(cd "$top" && pwd -P)"
  dir_real="$(cd "$DIR" && pwd -P)"
  [[ "$top" == "$dir_real" ]] \
    || fail "$DIR is inside another Git working tree rather than being the repository root."

  # If --repo was supplied, make sure a pre-existing directory is actually that
  # repository before changing branches in it. A clone made by this installer has
  # the normal origin URL, so this also catches accidental --dir collisions.
  if [[ -n "$REPO" ]]; then
    origin="$(git -C "$DIR" remote get-url origin 2>/dev/null || true)"
    [[ -n "$origin" ]] || fail "$DIR has no 'origin' remote, so it cannot be verified as $REPO."
    normalized_origin="$(normalize_repo_location "$origin")"
    [[ "$normalized_origin" == "$REPO" ]] \
      || fail "$DIR already contains a different repository (origin: $origin; expected: $REPO)."
  fi

  if [[ -n "$BRANCH" ]]; then
    current="$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

    # A local branch wins over an identically named tag, matching normal branch
    # expectations. If it is already checked out, no mutation is needed.
    if git -C "$DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      if [[ "$current" != "$BRANCH" ]]; then
        dirty="$(git -C "$DIR" status --porcelain --untracked-files=all)"
        [[ -z "$dirty" ]] \
          || fail "$DIR has local changes. Refusing to switch from '${current:-detached HEAD}' to '$BRANCH'; commit, stash, or remove them first."
        log "Switching existing clone from ${current:-detached HEAD} to branch $BRANCH..."
        git -C "$DIR" checkout --quiet "$BRANCH"
      fi
    elif git -C "$DIR" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
      dirty="$(git -C "$DIR" status --porcelain --untracked-files=all)"
      [[ -z "$dirty" ]] \
        || fail "$DIR has local changes. Refusing to create/switch to '$BRANCH'; commit, stash, or remove them first."
      log "Switching existing clone to branch $BRANCH (tracking origin/$BRANCH)..."
      git -C "$DIR" checkout --quiet -b "$BRANCH" --track "origin/$BRANCH"
    elif git -C "$DIR" show-ref --verify --quiet "refs/tags/$BRANCH"; then
      dirty="$(git -C "$DIR" status --porcelain --untracked-files=all)"
      [[ -z "$dirty" ]] \
        || fail "$DIR has local changes. Refusing to switch to tag '$BRANCH'; commit, stash, or remove them first."
      log "Switching existing clone to tag $BRANCH (detached HEAD)..."
      git -C "$DIR" checkout --quiet --detach "refs/tags/$BRANCH"
    else
      fail "Branch/tag '$BRANCH' is not present in the existing clone at $DIR. Nothing was changed. Fetch that ref first, or use a different --dir so the installer can clone it."
    fi
  fi

  if [[ ! -f "$DIR/flake.nix" ]]; then
    current="$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$DIR" describe --tags --exact-match 2>/dev/null || printf 'detached HEAD')"
    fail "$DIR is checked out at '$current', but that checkout has no flake.nix${BRANCH:+ (requested: '$BRANCH')}."
  fi
}

explain_auth() {
  if [[ "$HOST" == "github.com" ]]; then
    cat > /dev/tty <<EXPLAIN

$OWNER/$NAME needs you to sign in. Bootstrap credentials are not kept after cloning.

  Temporary token  Open a pre-filled GitHub page for a one-day, Contents: Read-only
                   fine-grained token. You select only $OWNER/$NAME, then copy and
                   paste the token once. The script revokes it after the clone.

  SSH              Clone with an SSH key that's already on your GitHub account.
                   No key yet? Quit, then run:
                     ssh-keygen -t ed25519
                   add the contents of ~/.ssh/id_ed25519.pub at
                     https://github.com/settings/keys
                   and re-run with --auth ssh. Unlike the token flow, this leaves
                   you set up for pulling and pushing later.

  Existing setup   Clone the way a plain git clone would on this machine, using
                   credential helpers already in your git config.

EXPLAIN
  else
    cat > /dev/tty <<EXPLAIN

$REPO needs you to sign in. Bootstrap credentials are not kept after cloning.

  Token            Paste a personal access token with read access to the repo,
                   created in your account settings on $HOST.

  SSH              Clone with an SSH key that's already on your $HOST account.
                   No key yet? Quit, run  ssh-keygen -t ed25519 , add the
                   contents of ~/.ssh/id_ed25519.pub to your account, and
                   re-run with --auth ssh.

  Existing setup   Clone the way a plain git clone would on this machine, using
                   credential helpers already in your git config.

EXPLAIN
  fi
}

do_clone() {
  case "$1" in
    token)    clone_token ;;
    ssh)      clone_ssh ;;
    existing) clone_existing ;;
  esac
}

if [[ $NEED_CLONE -eq 1 ]]; then
  if [[ "$MODE" == "dry-run" ]]; then
    dry "$CLONE_PLAN"
    dry "Stopping here: nothing to evaluate without the repo."
    exit 0
  fi

  ensure_git || fail "git is needed to clone and couldn't be found or fetched."

  # Remember the first folder we create, so an unfinished clone leaves nothing behind
  d="$(dirname "$DIR")"
  while [[ ! -e "$d" ]]; do CREATED_TOP="$d"; d="$(dirname "$d")"; done
  mkdir -p "$(dirname "$DIR")"
  log "Cloning $REPO${BRANCH:+ at branch/tag $BRANCH} into $DIR..."

  USED_AUTH="$AUTH"
  if [[ "$AUTH" == "auto" ]]; then
    if clone_anonymous; then
      USED_AUTH="none"
    else
      if [[ "$HOST" == "github.com" ]]; then
        CHOICES=("Temporary read-only token (recommended)" "SSH" "Existing setup" "Quit")
      else
        CHOICES=("Token" "SSH" "Existing setup" "Quit")
      fi
      while true; do
        explain_auth
        CHOICE=""
        PS3="How do you want to sign in? "
        select CHOICE in "${CHOICES[@]}"; do
          [[ -n "$CHOICE" ]] && break
        done < /dev/tty
        case "$CHOICE" in
          "Temporary read-only token (recommended)") USED_AUTH="token" ;;
          "SSH")             USED_AUTH="ssh" ;;
          "Existing setup")  USED_AUTH="existing" ;;
          *)                 fail "Stopped before cloning. Nothing else was changed." ;;
        esac
        if do_clone "$USED_AUTH"; then break; fi
        log "That didn't work. Try again or pick another method."
      done
    fi
  else
    do_clone "$AUTH" || fail "Cloning $REPO with --auth $AUTH failed."
  fi

  CLONED=1
  log "Cloned $REPO${BRANCH:+ at branch/tag $BRANCH} into $DIR"
  if [[ "$USED_AUTH" == "token" ]]; then
    log "No bootstrap credentials were kept, so pulling or pushing later needs your own setup (an SSH key, or a git credential helper from your config)."
  fi
else
  if [[ $EXISTING_GIT_REPO -eq 1 ]]; then
    if [[ "$MODE" == "dry-run" ]]; then
      if [[ -n "$BRANCH" ]]; then
        dry "Would reuse $DIR and switch it to branch/tag '$BRANCH' if needed; the switch would be refused if the worktree has local changes"
        if [[ ! -f "$DIR/flake.nix" ]]; then
          dry "The current checkout has no flake.nix, so evaluation cannot continue without performing that branch switch."
          exit 0
        fi
      fi
    else
      prepare_existing_repo
    fi
  else
    [[ -z "$BRANCH" ]] || fail "--branch requires a Git clone, but $DIR is only an existing flake directory."
    [[ -f "$DIR/flake.nix" ]] || fail "$DIR has no flake.nix."
  fi
  log "Using existing clone: $DIR${BRANCH:+ at branch/tag $BRANCH}"
fi

# ---------------------------------------------------------------------------
# 5. Lock file
#    Build/evaluation commands are protected from lock mutation by default. A
#    candidate lock is generated only in $WORK so we can detect missing/stale
#    locks before asking permission to modify the repository.
# ---------------------------------------------------------------------------
lock_candidate() {
  local candidate="$WORK/flake.lock.candidate"
  rm -f "$candidate"
  nixf flake lock --output-lock-file "$candidate" "$DIR" >/dev/null
  [[ -f "$candidate" ]] || return 1
  printf '%s' "$candidate"
}

write_flake_lock() {
  log "Creating/updating $DIR/flake.lock..."
  nixf flake lock "$DIR"
}

prepare_flake_lock() {
  local candidate="" differs=0

  if [[ "$MODE" == "dry-run" ]]; then
    if [[ -f "$DIR/flake.lock" ]]; then
      FLAKE_LOCK_FLAGS=(--no-update-lock-file --no-write-lock-file)
      return 0
    fi
    # With no lock file there is nothing to freeze. Let Nix resolve one in memory,
    # but explicitly forbid writing it to the repository.
    warn "$DIR/flake.lock does not exist. Dry-run will resolve inputs temporarily and will not save a lock file."
    FLAKE_LOCK_FLAGS=(--no-write-lock-file)
    return 0
  fi

  if [[ $WRITE_LOCK_FILE -eq 1 ]]; then
    write_flake_lock
    FLAKE_LOCK_FLAGS=(--no-update-lock-file --no-write-lock-file)
    return 0
  fi

  if ! candidate="$(lock_candidate)"; then
    fail "Could not resolve the flake inputs while checking flake.lock. Nothing was written to the repository."
  fi

  if [[ ! -f "$DIR/flake.lock" ]]; then
    differs=1
    confirm "$DIR/flake.lock is missing. Create it now?" \
      || fail "A lock file is required for a normal run. Re-run with --write-lock-file to create it non-interactively."
  elif ! cmp -s "$candidate" "$DIR/flake.lock"; then
    differs=1
    confirm "$DIR/flake.lock is not current for flake.nix. Update it now?" \
      || fail "Refusing to continue with a stale lock file. Re-run with --write-lock-file to update it non-interactively."
  fi

  if [[ $differs -eq 1 ]]; then
    write_flake_lock
    cmp -s "$candidate" "$DIR/flake.lock" \
      || fail "The written flake.lock did not match the lock state that was just resolved; refusing to continue."
  fi

  FLAKE_LOCK_FLAGS=(--no-update-lock-file --no-write-lock-file)
}

# Restore an unexpected lock mutation before reporting failure. This is defense
# in depth for rebuild tools that invoke Nix internally and don't expose every
# flake-lock CLI flag directly.
run_with_lock_guard() {
  local backup="$WORK/flake.lock.guard" had_lock=0 status=0 changed=0
  rm -f "$backup"
  if [[ -f "$DIR/flake.lock" ]]; then
    cp "$DIR/flake.lock" "$backup"
    had_lock=1
  fi

  set +e
  "$@"
  status=$?
  set -e

  if [[ $had_lock -eq 1 ]]; then
    if [[ ! -f "$DIR/flake.lock" ]] || ! cmp -s "$backup" "$DIR/flake.lock"; then
      cp "$backup" "$DIR/flake.lock"
      changed=1
    fi
  elif [[ -e "$DIR/flake.lock" ]]; then
    rm -f "$DIR/flake.lock"
    changed=1
  fi

  if [[ $changed -eq 1 ]]; then
    fail "A command unexpectedly modified flake.lock; the original lock state was restored."
  fi
  return "$status"
}

prepare_flake_lock

# ---------------------------------------------------------------------------
# 6. Configuration
# ---------------------------------------------------------------------------
if [[ -z "$CONFIG" ]]; then
  if [[ "$METHOD" == "home-manager" ]]; then
    # Only offer configs built for this machine's platform
    SYSTEM="$(nixf eval --impure --raw --expr builtins.currentSystem)"
    APPLY="cs: builtins.concatStringsSep \"\\n\" (builtins.attrNames (builtins.filterAttrs (_: c: c.pkgs.stdenv.hostPlatform.system == \"$SYSTEM\") cs))"
  else
    APPLY='cs: builtins.concatStringsSep "\n" (builtins.attrNames cs)'
  fi

  NAMES="$(nix_flake eval --raw "$DIR#$ATTR" --apply "$APPLY")"
  [[ -n "$NAMES" ]] || fail "No matching $ATTR found in $DIR/flake.nix."
  # shellcheck disable=SC2206
  CONFIGS=($NAMES)

  if [[ ${#CONFIGS[@]} -eq 1 ]]; then
    CONFIG="${CONFIGS[0]}"
  else
    PS3="Choose a configuration: "
    select CONFIG in "${CONFIGS[@]}"; do
      [[ -n "$CONFIG" ]] && break
    done < /dev/tty
    [[ -n "$CONFIG" ]] || fail "No configuration chosen."
  fi
fi
log "Configuration: $ATTR.$CONFIG"

REF="$DIR#$ATTR.$CONFIG.$OUTPUT"
case "$METHOD" in
  darwin)       NEXT="sudo darwin-rebuild switch --flake $DIR#$CONFIG" ;;
  nixos)        NEXT="sudo nixos-rebuild switch --flake $DIR#$CONFIG" ;;
  home-manager) NEXT="home-manager switch --flake $DIR#$CONFIG" ;;
esac

# ---------------------------------------------------------------------------
# 7. Dry run, build, VM, or activate
# ---------------------------------------------------------------------------
case "$MODE" in
  dry-run)
    dry "Evaluating $ATTR.$CONFIG (no output below means everything is already built or cached locally):"
    nix_flake build --dry-run "$REF"
    dry "Evaluation succeeded. A real run would activate it (first time via nix run, later with: $NEXT)"
    ;;

  build)
    log "Building $ATTR.$CONFIG without activating..."
    nix_flake build --out-link "$DIR/result" "$REF"
    log "Build succeeded: $DIR/result -> $(readlink "$DIR/result")"
    ;;

  vm)
    log "Building a VM from $ATTR.$CONFIG..."
    nix_flake build --out-link "$DIR/result" "$REF"
    log "Build succeeded. Start the VM with:  $DIR/result/bin/run-*-vm"
    ;;

  switch)
    case "$METHOD" in
      darwin)
        log "Activating nix-darwin (needs sudo)..."
        # nix-darwin's documented bootstrap, using the version pinned in flake.lock
        run_with_lock_guard sudo env "NIX_CONFIG=$NIX_FEATURE_CONFIG" \
          "$(command -v nix)" "${NIX_FLAGS[@]}" run "${FLAKE_LOCK_FLAGS[@]}" \
          --inputs-from "$DIR" nix-darwin#darwin-rebuild -- switch --flake "$DIR#$CONFIG"
        ;;
      nixos)
        HW="$DIR/hosts/$CONFIG/hardware-configuration.nix"
        if [[ -f "$HW" ]] && confirm "Replace $HW with one generated for this machine?"; then
          sudo nixos-generate-config --show-hardware-config > "$HW"
          log "Wrote $HW. Remember to commit it."
        fi
        log "Activating NixOS configuration (needs sudo)..."
        run_with_lock_guard sudo env "NIX_CONFIG=$NIX_FEATURE_CONFIG" \
          nixos-rebuild switch --flake "$DIR#$CONFIG"
        ;;
      home-manager)
        log "Activating home-manager..."
        NIX_CONFIG="$(nix_config_with_features)" run_with_lock_guard \
          nix_flake run --inputs-from "$DIR" home-manager -- switch --flake "$DIR#$CONFIG"
        ;;
    esac
    log "Done! Open a new terminal to pick up your environment."
    log "Apply future changes with:  $NEXT"
    ;;
esac