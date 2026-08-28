#!/bin/sh
# Removes everything install.sh added. Packages are left installed.
set -u
cd "$(dirname "$0")"

systemctl --user disable --now hp-camera-relay.service 2>/dev/null || true
rm -f ~/.config/systemd/user/hp-camera-relay.service
systemctl --user daemon-reload

sudo dkms remove hi556-hp/1.0 --all 2>/dev/null || true
sudo rm -rf /usr/src/hi556-hp-1.0
sudo rm -f /etc/modprobe.d/v4l2loopback.conf

if [ -f /usr/share/libcamera/ipa/simple/hi556.yaml.broken ]; then
    sudo mv /usr/share/libcamera/ipa/simple/hi556.yaml.broken \
            /usr/share/libcamera/ipa/simple/hi556.yaml
fi

echo "Removed. Reboot to go back to the stock hi556 driver."
