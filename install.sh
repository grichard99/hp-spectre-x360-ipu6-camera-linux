#!/bin/sh
# Installs the patched hi556 driver (DKMS) and the virtual webcam relay.
# Run as your normal user from the repo directory. It calls sudo where needed.
# Tested on Arch Linux (kernel 7.1.x). Adjust the package step for other distros.
set -eu

cd "$(dirname "$0")"

echo "==> Installing packages"
sudo pacman -S --needed dkms linux-headers libcamera libcamera-tools \
    pipewire-libcamera gst-plugin-libcamera v4l2loopback-dkms v4l2-relayd

echo "==> Installing patched hi556 driver via DKMS"
sudo rm -rf /usr/src/hi556-hp-1.0
sudo cp -r dkms/hi556-hp-1.0 /usr/src/hi556-hp-1.0
sudo dkms install hi556-hp/1.0 -k "$(uname -r)"

echo "==> Retiring stale libcamera tuning file, if present"
if [ -f /usr/share/libcamera/ipa/simple/hi556.yaml ]; then
    sudo mv /usr/share/libcamera/ipa/simple/hi556.yaml \
            /usr/share/libcamera/ipa/simple/hi556.yaml.broken
fi

echo "==> Configuring v4l2loopback"
sudo cp vcam/v4l2loopback.conf /etc/modprobe.d/v4l2loopback.conf
# The package's system-level relay runs in a sandbox that breaks the GPU ISP.
sudo systemctl disable --now v4l2-relayd.service 2>/dev/null || true
sudo rm -f /etc/v4l2-relayd.d/*.conf

echo "==> Installing user relay service"
mkdir -p ~/.config/systemd/user
cp vcam/hp-camera-relay.service ~/.config/systemd/user/hp-camera-relay.service
systemctl --user daemon-reload
systemctl --user enable hp-camera-relay.service

echo "==> Reloading kernel modules"
systemctl --user stop wireplumber
sudo modprobe -r intel_ipu6_isys hi556 2>/dev/null || true
sudo modprobe hi556
sudo modprobe intel_ipu6_isys
sudo modprobe -r v4l2loopback 2>/dev/null || true
sudo modprobe v4l2loopback
systemctl --user restart hp-camera-relay.service
sleep 3
systemctl --user start wireplumber

echo
echo "hi556 module in use: $(modinfo -n hi556)"
echo "Done. Test with:  cam -c1 -C30      (libcamera direct)"
echo "            and:  v4l2-ctl -d /dev/video42 --stream-mmap --stream-count=90   (virtual webcam)"
echo "In apps, pick the camera named \"HP Wide Vision HD Camera\"."
