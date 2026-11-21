#!/bin/bash
# Install upmpdcli (UPnP renderer -> MPD) with the Qobuz plugin on the streamer.
#
# The upmpdcli apt repo (lesbonscomptes.com) has no armhf build of the core
# packages for trixie, so libnpupnp, libupnpp and upmpdcli are built from the
# repo's source packages (about an hour on the A7). Run as root on the box.
set -Eeuo pipefail

REPO=https://www.lesbonscomptes.com/upmpdcli/downloads/debian
KEY_FPR="F8E334725692 2A8AE767605B7808CE96D38B9201"
KEY_FPR="${KEY_FPR// /}"
BUILD=/root/upmpdcli-build
CONF_SRC="$(dirname "$0")/../upmpdcli/upmpdcli.conf"
[[ -f $CONF_SRC ]] || CONF_SRC="$(dirname "$0")/upmpdcli.conf"

trap 'echo "ERROR: failed at line $LINENO"' ERR
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

if [[ ! -f /usr/share/keyrings/upmpdcli.gpg ]]; then
    tmp=$(mktemp); curl -sf "$REPO/dists/trixie/dockes.gpg" -o "$tmp"
    gpg --show-keys --with-colons "$tmp" | grep -q "^fpr:::::::::$KEY_FPR:" \
        || { echo "ERROR: unexpected repo key"; exit 1; }
    gpg --dearmor < "$tmp" > /usr/share/keyrings/upmpdcli.gpg
fi
cat > /etc/apt/sources.list.d/upmpdcli.sources <<EOS
Types: deb deb-src
URIs: $REPO/
Suites: trixie
Components: main
Architectures: armhf
Signed-By: /usr/share/keyrings/upmpdcli.gpg
EOS
apt-get update
apt-get install -y --no-install-recommends build-essential devscripts fakeroot

mkdir -p "$BUILD"; cd "$BUILD"
for p in libnpupnp libupnpp upmpdcli; do
    ls ${p}[0-9]*_armhf.deb ${p}_*_armhf.deb >/dev/null 2>&1 && continue
    apt-get source "$p"
    (cd "$(ls -d "$p"-*/ | head -1)" && apt-get build-dep -y . \
        && dpkg-buildpackage -us -uc -b -j3)
    case $p in
        libnpupnp) apt-get install -y ./libnpupnp13_*.deb ./libnpupnp-dev_*.deb ;;
        libupnpp)  apt-get install -y ./libupnpp17_*.deb ./libupnpp-dev_*.deb ;;
    esac
done
apt-get install -y ./upmpdcli_*_armhf.deb ./upmpdcli-qobuz_*_all.deb

[[ -f /etc/upmpdcli.conf && ! -f /etc/upmpdcli.conf.orig ]] && cp -a /etc/upmpdcli.conf /etc/upmpdcli.conf.orig
install -m 644 "$CONF_SRC" /etc/upmpdcli.conf
systemctl enable --now upmpdcli
systemctl restart upmpdcli
echo "Done. Log in to Qobuz once: python3 /usr/share/upmpdcli/cdplugins/qobuz/qobuz-init-oauth.py"
