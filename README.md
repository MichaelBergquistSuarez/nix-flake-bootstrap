# nix-flake-bootstrap

Bootstrap a fresh machine from a Nix flake with minimal pre-existing dependencies.

`nix-flake-bootstrap` sets up **NixOS**, **nix-darwin**, or **Home Manager** from a Git repository. It is intended to work even on machines that do not already have Nix or Git installed.

It can:

- install Nix when needed;
- obtain Git temporarily through Nix when Git is unavailable;
- clone public or private repositories;
- authenticate to private GitHub repositories without permanently storing the bootstrap credential;
- select a branch, tag, and flake configuration;
- build or activate NixOS, nix-darwin, or Home Manager.

## Quick start

Run the installer and point it at the repository containing your flake:

```bash
curl -fsSL https://raw.githubusercontent.com/MichaelBergquistSuarez/nix-flake-bootstrap/main/install.sh \
  | bash -s -- --repo you/nix-config
```

Replace `you/nix-config` with your repository.

From there, the script handles the rest: installing Nix if necessary, obtaining Git if necessary, cloning the repository, authenticating if necessary, selecting the configuration, and activating it.

Run it as your normal user. `sudo` is requested only when required.

## Configurations

The optional `config` argument selects an attribute from the relevant flake output.

For example:

| Flake output | `config` |
| --- | --- |
| `nixosConfigurations.desktop` | `desktop` |
| `darwinConfigurations.macbook` | `macbook` |
| `homeConfigurations."alice@laptop"` | `alice@laptop` |

```bash
./install.sh nixos desktop
```

On NixOS, the method can normally be omitted:

```bash
./install.sh desktop
```

Defaults:

- macOS → `darwin`
- NixOS → `nixos`
- other Linux → `home-manager`

If no config is given, the script selects the only matching configuration or shows a menu when there are several.

## Branches and tags

Use the repository's default branch:

```bash
./install.sh --repo owner/nix-config
```

Or select another branch or tag:

```bash
./install.sh \
  --repo owner/nix-config \
  --branch testing
```

Existing clones can be reused and switched to the requested branch when the working tree is clean. Local changes are never discarded automatically.

## Private repositories

If an anonymous clone fails, the script lets you authenticate using:

- a temporary fine-grained GitHub token;
- an existing SSH key;
- your existing Git credential setup.

The recommended fresh-machine GitHub flow opens a pre-filled token form with:

```text
Expiration: 1 day
Contents:   Read-only
```

Select only the repository being bootstrapped, generate the token, and paste it into the terminal.

The token is used only for cloning, is not written to Git configuration or the credential manager, and is revoked immediately after the clone attempt.

```bash
./install.sh \
  --repo owner/private-config \
  --auth token
```

## `flake.lock`

Existing lock files are protected from implicit changes.

If `flake.lock` is missing or needs updating, the script asks before writing it.

To explicitly allow creating or updating it:

```bash
./install.sh \
  --repo owner/nix-config \
  --write-lock-file
```

`--dry-run` never writes the lock file.

## Nix installation

If Nix is missing, the script installs it using the official Nix installer.

By default:

```text
--nix-install auto
```

Multi-user Nix is preferred where supported. On Linux systems where it is unavailable, the script explains why and asks before falling back to single-user installation.

You can choose explicitly:

```bash
--nix-install multi-user
--nix-install single-user
```

The script does not permanently modify `nix.conf` just to enable flakes for the bootstrap process.

## Other modes

Build without activating:

```bash
./install.sh --build nixos desktop
```

Evaluate without activating:

```bash
./install.sh --dry-run nixos desktop
```

Build a NixOS VM:

```bash
./install.sh --vm desktop
```

## Full example

```bash
curl -fsSL https://raw.githubusercontent.com/MichaelBergquistSuarez/nix-flake-bootstrap/main/install.sh \
  | bash -s -- \
      --repo owner/nix-config \
      --branch testing \
      --dir "$HOME/src/nix-config" \
      --auth token \
      nixos desktop
```

Run:

```bash
./install.sh --help
```

for the complete option reference.

## Security

This script is designed to bootstrap an entire machine, so both the bootstrapper and the flake it activates should be treated as trusted code.

If you prefer to inspect the script first:

```bash
curl -fSLo install.sh \
  https://raw.githubusercontent.com/MichaelBergquistSuarez/nix-flake-bootstrap/main/install.sh

less install.sh

bash install.sh --repo owner/nix-config
```

Do not put plaintext secrets directly in your flake; Nix source files may be copied into the Nix store.

## What this project is

This is a bootstrapper, not a Nix configuration framework.

You provide the flake. `nix-flake-bootstrap` gets a fresh machine to the point where that flake can take over and declaratively configure the rest.
