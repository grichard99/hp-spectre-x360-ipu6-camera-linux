# HP Spectre x360 14 (Alder Lake) webcam on Linux: hi556 + Intel IPU6, mainline kernel

Working integrated webcam on the HP Spectre x360 2-in-1 14-ef (12th gen Intel, IPU6, Hynix hi556 sensor)
with the plain mainline kernel. No Intel out-of-tree stack (ipu6-drivers, ipu6-camera-hal, icamerasrc),
no proprietary blobs beyond the IPU6 firmware already in linux-firmware.

The fix is a one-line timing change in the kernel's `hi556` sensor driver, shipped here as a DKMS
module, plus a virtual webcam so that Chrome, Chromium, Discord and other V4L2-only apps can use it.

Tested on:

| Component | Version |
|---|---|
| Laptop | HP Spectre x360 2-in-1 14-ef0xxx, BIOS F.27 |
| Sensor | Hynix hi556 (ACPI `INT3537`), IPU6 CSI-2 port 3, 2 lanes |
| Distro | Arch Linux (Omarchy) |
| Kernel | 7.1.9 |
| libcamera | 0.7.2 |
| PipeWire | 1.6.8 |
| v4l2loopback | 0.15.4, v4l2-relayd 0.2.0 |

Other Spectre x360 14-ef variants and other laptops with a hi556 behind a Lattice MIPI aggregator
are likely affected too. If it works for you on different hardware, please open an issue and say so.

## Symptoms

- `lsmod` shows `hi556`, `intel_ipu6`, `intel_ipu6_isys` loaded and `/dev/video0` to `/dev/video31` exist.
- `cam -l` (libcamera-tools) lists the camera. PipeWire shows a `hi556` source.
- The privacy LED turns on when an app opens the camera.
- No frames ever arrive. `dmesg` shows, on every attempt:

```
intel_ipu6_isys.isys intel_ipu6.isys.40: stream stop time out
intel_ipu6_isys.isys intel_ipu6.isys.40: stream close time out
```

- Everything the kernel controls looks correct in debugfs while streaming: regulators enabled, reset
  released, sensor clock (`INT3472:01-clk`) enabled, chip ID read fine over I2C.

## Cause

The mainline driver `drivers/media/i2c/hi556.c` powers the sensor on, releases the reset line, waits
5 ms and starts programming it. On this HP the sensor sits behind a Lattice MIPI aggregator (the
INT3472 "handshake" pin, which the mainline int3472 driver exposes as the `dvdd` regulator). That
aggregator needs a few hundred milliseconds after reset before it passes pixel data. Within the 5 ms
window the sensor already answers I2C and lights the LED, so every diagnostic looks healthy, but the IPU
never sees a start-of-frame.

Intel's out-of-tree `hi556.c` waits 25 ms and its userspace HAL adds seconds of startup slack, which is
why the old proprietary stack worked on this laptop and mainline did not.

Measured: 5 ms fails, 50 ms fails, 300 ms works reliably. The patch:

```diff
--- a/drivers/media/i2c/hi556.c
+++ b/drivers/media/i2c/hi556.c
@@ hi556_resume
 	if (hi556->reset_gpio) {
 		/* Assert reset for at least 2ms on back to back off-on */
 		usleep_range(2000, 2200);
 		gpiod_set_value_cansleep(hi556->reset_gpio, 0);
 	}

-	usleep_range(5000, 5500);
+	msleep(300);
 	return 0;
```

The driver in this repo makes that delay a module parameter (`settle_ms`, default 300) so it can be
tuned on other hardware without rebuilding. `hi556-settle.patch` is the full diff against mainline.

## Quick install (Arch Linux)

```
git clone https://github.com/grichard99/hp-spectre-x360-ipu6-camera-linux
cd hp-spectre-x360-ipu6-camera-linux
./install.sh
```

Then test:

```
cam -c1 -C30        # direct libcamera capture, expect 30 "seq:" lines
qcam                # live preview window
```

In Chrome/Chromium, Discord, Meet, Zoom and friends, pick the camera named
**HP Wide Vision HD Camera**. Do not pick `hi556` or any `ipu6` entry (see Part 3 for why).

Uninstall with `./uninstall.sh`.

## Step by step (what install.sh does, for other distros)

### Part 1: patched hi556 driver via DKMS

Requirements: kernel headers, `dkms`, a kernel with `CONFIG_VIDEO_HI556=m` and mainline IPU6 support
(6.10 or newer; IPU6 ISYS went mainline in 6.10).

```
sudo cp -r dkms/hi556-hp-1.0 /usr/src/hi556-hp-1.0
sudo dkms install hi556-hp/1.0 -k "$(uname -r)"
```

The module installs to `/lib/modules/<kernel>/updates/dkms/` which depmod searches before the
kernel's own modules, so the patched driver is picked automatically, including after kernel updates
(DKMS rebuilds it). Check with:

```
modinfo -n hi556      # must end in updates/dkms/hi556.ko.zst (or .ko)
```

Reload without rebooting:

```
systemctl --user stop wireplumber        # it holds the camera open
sudo modprobe -r intel_ipu6_isys hi556
sudo modprobe hi556 && sudo modprobe intel_ipu6_isys
systemctl --user start wireplumber
```

If you prefer to patch a distro kernel instead, apply `hi556-settle.patch`.

### Part 2: libcamera

Install `libcamera`, `libcamera-tools`, `pipewire-libcamera` and `gst-plugin-libcamera`. libcamera's
"simple" pipeline handler with the software ISP drives the IPU6 on this laptop. Frames are debayered on
the Intel Xe GPU.

If an earlier attempt left a hand-written tuning file at
`/usr/share/libcamera/ipa/simple/hi556.yaml`, remove it. Old ones reference a `Lut` algorithm that
libcamera 0.7 renamed, and the software ISP then fails to start. Without the file libcamera falls back
to its own `uncalibrated.yaml`, which works.

At this point `cam` and `qcam` work.

### Part 3: virtual webcam for browsers and Electron apps

Two problems remain for real applications:

- Chromium's PipeWire camera path only accepts YUV style formats. The libcamera PipeWire node offers
  only RGBA/BGRx, so Google Meet shows "Camera is starting" forever.
- Electron apps such as Discord only enumerate V4L2 devices. The IPU6 exposes 32 raw `/dev/videoN`
  nodes that switch the LED on but can never deliver usable frames.

The answer is a v4l2loopback device fed on demand by `v4l2-relayd`, which starts a GStreamer pipeline
only while an application has the device open, so the LED follows real use.

```
sudo pacman -S v4l2loopback-dkms v4l2-relayd     # both in the Arch/AUR repos
sudo cp vcam/v4l2loopback.conf /etc/modprobe.d/v4l2loopback.conf
sudo modprobe v4l2loopback
```

`vcam/v4l2loopback.conf`:

```
options v4l2loopback devices=1 video_nr=42 exclusive_caps=1 max_buffers=8 card_label="HP Wide Vision HD Camera"
```

`exclusive_caps=1` is required; without it Chromium refuses to list the device.

Do not use the `v4l2-relayd@.service` that the package ships. It runs as root inside a systemd sandbox
that blocks the dma-buf devices the GPU software ISP needs, and you get a black picture. Run the relay
as a user service instead:

```
mkdir -p ~/.config/systemd/user
cp vcam/hp-camera-relay.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now hp-camera-relay.service
systemctl --user restart wireplumber
```

The relay pipeline is:

```
libcamerasrc ! video/x-raw,width=1920,height=1080 ! videoconvert ! videoscale
   -> appsrc caps=YUY2,1280x720,30/1 ! videoconvert ! v4l2sink device=/dev/video42 sync=false
```

Three details in there each produce "LED on, black video" when wrong:

1. **Capture at 1920x1080, not 1280x720.** Asking libcamera for 720p selects the sensor's 1296x722
   binned mode, and on this module that mode delivers zero-byte frames. 1080p and full 2592x1944 work.
   `videoscale` downsizes to 720p for the apps.
2. **`sync=false` on `v4l2sink`.** Without it the relay clock-syncs buffers that were stamped by a
   different pipeline and output drops to about 1 fps.
3. **Start the relay before wireplumber** (`Before=wireplumber.service` plus a short delay). With
   `exclusive_caps=1` the loopback only announces capture capability while a writer is attached. If
   wireplumber probes it first, PipeWire never creates a node and Chromium never lists it.

Verify:

```
v4l2-ctl -d /dev/video42 --stream-mmap --stream-count=300     # about 30 fps
gst-launch-1.0 v4l2src device=/dev/video42 ! videoconvert ! autovideosink
```

Your user must be in the `video` group.

## Troubleshooting

| Symptom | Check |
|---|---|
| Camera stopped working after a kernel update | `modinfo -n hi556` should point at `updates/dkms`. If not: `sudo dkms install hi556-hp/1.0` |
| `rmmod hi556` says module is in use | `systemctl --user stop wireplumber`, and close any app using the camera |
| Apps see the camera but the picture is black | `journalctl --user -u hp-camera-relay` for libcamera errors; make sure the relay is the user service, not the system one |
| Choppy, about 1 fps | The `sync=false` on `v4l2sink` is missing |
| Chromium does not list "HP Wide Vision HD Camera" | `systemctl --user restart wireplumber` while the relay is running |
| Picture is dark | Expected for now: libcamera's generic tuning has no calibrated AE/AWB for hi556. Good light helps. |

Useful root-level readings while a capture is running:

```
sudo grep INT3472 /sys/kernel/debug/clk/clk_summary
sudo grep -E 'reset|privacy|avdd|dvdd' /sys/kernel/debug/gpio
sudo cat /sys/kernel/debug/regulator/regulator_summary
journalctl -k | grep -E 'stream (on|off) CSI2|time out'
```

## Files

```
dkms/hi556-hp-1.0/     patched hi556.c, Makefile, dkms.conf
hi556-settle.patch     the same change as a diff against mainline
vcam/                  v4l2loopback modprobe config and the user relay service
install.sh             Arch install of everything above
uninstall.sh           reverts install.sh
```

## Still open

- A proper `hi556.yaml` tuning file for libcamera's simple IPA would fix the dark image.
- The delay should go upstream to linux-media, either as a DMI quirk for this laptop family or as a
  larger default (300 ms at power-on is harmless elsewhere).

## Licence

GPL-2.0, same as the kernel driver this is derived from.
