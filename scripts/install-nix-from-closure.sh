#! /usr/bin/env bash

set -e

dest="/nix"
self="$(dirname "$0")"
nix="@nix@"
cacert="@cacert@"
default_channel_url="https://nixos.org/channels/nixpkgs-unstable"
channel_url="$default_channel_url"
default_channel_name="nixpkgs"
channel_name="$default_channel_name"

for arg in "$@"; do
    case "$arg" in
        --help)
            echo "Nix install script"
            echo ""
            echo "Usage: $(basename "$0") [options]"
            echo ""
            echo "Options:"
            echo "  --channel=URL"
            echo "          The Nix channel to get expressions from."
            echo "          If URL is empty, no channel will be registered."
            echo "          Default: $default_channel_url"
            echo ""
            echo "  --channel-name=NAME"
            echo "          Optional name to give the Nix channel."
            echo "          Default: $default_channel_name"
            exit 0
            ;;
        --channel=*)
            channel_url=$(echo "$arg" | cut -d= -f2)
            ;;
        --channel-name=*)
            channel_name=$(echo "$arg" | cut -d= -f2)
            ;;
        *) echo "Unsupported argument: $arg"
           echo "Try --help"
           exit 1
           ;;
    esac
done

if ! [ -e $self/.reginfo ]; then
    echo "$0: incomplete installer (.reginfo is missing)" >&2
    exit 1
fi

# macOS support for 10.10 or higher
if [ "$(uname -s)" = "Darwin" ] && [ $(($(sw_vers -productVersion | cut -d '.' -f 2))) -lt 10 ]; then
    echo "$0: macOS $(sw_vers -productVersion) is not supported, upgrade to 10.10 or higher"
    exit 1
fi

if [ -z "$USER" ]; then
    echo "$0: \$USER is not set" >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    printf '\e[1;31mwarning: installing Nix as root is not supported by this script!\e[0m\n'
fi

echo "performing a single-user installation of Nix..." >&2

if ! [ -e "$dest" ]; then
    cmd="mkdir -m 0755 $dest && chown $USER $dest"
    echo "directory $dest does not exist; creating it by running ‘$cmd’ using sudo" >&2
    if ! sudo sh -c "$cmd"; then
        echo "$0: please manually run ‘$cmd’ as root to create $dest" >&2
        exit 1
    fi
fi

if ! [ -w "$dest" ]; then
    echo "$0: directory $dest exists, but is not writable by you; please run ‘chown -R $USER $dest’ as root" >&2
    exit 1
fi

mkdir -p "$dest/store"

echo -n "copying Nix to $dest/store..." >&2

for i in $(cd $self/store >/dev/null && echo *); do
    echo -n "." >&2
    i_tmp="$dest/store/$i.$$"
    if [ -e "$i_tmp" ]; then
        rm -rf "$i_tmp"
    fi
    if ! [ -e "$dest/store/$i" ]; then
        cp -Rp "$self/store/$i" "$i_tmp"
        mv "$i_tmp" "$dest/store/$i"
    fi
done
echo "" >&2

echo "initialising Nix database..." >&2
if ! "$nix/bin/nix-store" --init; then
    echo "$0: failed to initialize the Nix database" >&2
    exit 1
fi

if ! $nix/bin/nix-store --load-db < $self/.reginfo; then
    echo "$0: unable to register valid paths" >&2
    exit 1
fi

. $nix/etc/profile.d/nix.sh

if ! $nix/bin/nix-env -i "$nix"; then
    echo "$0: unable to install Nix into your default profile" >&2
    exit 1
fi

# Install an SSL certificate bundle.
if [ -z "$NIX_SSL_CERT_FILE" -o ! -f "$NIX_SSL_CERT_FILE" ]; then
    "$nix/bin/nix-env" -i "$cacert"
    export NIX_SSL_CERT_FILE="$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt"
fi

if [ -n "$channel_url" ]; then
    # Subscribe the user to the Nixpkgs channel and fetch it.
    if ! "$nix/bin/nix-channel" --list | grep -q "^$channel_name "; then
        "$nix/bin/nix-channel" --add "$channel_url" "$channel_name"
    fi
    if [ -z "$_NIX_INSTALLER_TEST" ]; then
        "$nix/bin/nix-channel" --update "$channel_name"
    fi
fi

# Make the shell source nix.sh during login.
p=$NIX_LINK/etc/profile.d/nix.sh

added=
for i in .bash_profile .bash_login .profile; do
    fn="$HOME/$i"
    if [ -w "$fn" ]; then
        if ! grep -q "$p" "$fn"; then
            echo "modifying $fn..." >&2
            echo "if [ -e $p ]; then . $p; fi # added by Nix installer" >> $fn
        fi
        added=1
        break
    fi
done

if [ -z "$added" ]; then
    cat >&2 <<EOF

Installation finished!  To ensure that the necessary environment
variables are set, please add the line

  . $p

to your shell profile (e.g. ~/.profile).
EOF
else
    cat >&2 <<EOF

Installation finished!  To ensure that the necessary environment
variables are set, either log in again, or type

  . $p

in your shell.
EOF
fi
