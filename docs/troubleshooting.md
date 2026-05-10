# Troubleshooting — LFS 13.0 (jbird)

A detailed record of every significant problem encountered during the jbird build, the root cause analysis for each, and the solution applied. This document is written for someone attempting to reproduce or adapt this build on similar hardware.

---

## 1. GRUB Hung on Boot — No Display Output

**Symptom**
After installing GRUB and rebooting, the system produced no display output. The machine appeared to POST normally but never presented a boot menu or kernel output. Hard power cycle required.

**Root Cause**
GRUB's video mode negotiation failed on this hardware due to a dual-GPU configuration — an NVIDIA GeForce GTX 970 (discrete) and an Intel HD 4600 (integrated). GRUB attempted to switch video modes during early boot and hung when neither GPU responded correctly. The NVIDIA GPU has no open-source firmware support in the kernel tree; the Intel GPU exhibited initialization issues in this configuration.

**Solution**
Replaced GRUB entirely with `systemd-boot`. systemd-boot is a UEFI-native bootloader that does not perform video mode negotiation — it hands off directly to the kernel via UEFI, bypassing the GPU entirely during the boot sequence.

```bash
bootctl install --path=/boot
```

Boot entry written to `/boot/loader/entries/lfs.conf`:
```
title   Linux From Scratch 13.0
linux   /vmlinuz-6.18.10-lfs
options root=/dev/sdb1 rw nouveau.modeset=0 i915.modeset=0 module_blacklist=i915
```

**Lesson**
On systems with dual GPUs or problematic video hardware, systemd-boot is a more reliable choice than GRUB for UEFI systems. GRUB's video subsystem adds complexity that is unnecessary on headless or server-class machines.

---

## 2. Kernel Panic on Boot — Root Device Not Found

**Symptom**
After switching to systemd-boot, the kernel loaded but immediately panicked with:

```
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

**Root Cause**
The initial boot entry used `root=UUID=<uuid>` to identify the root partition. The kernel could not resolve the UUID at boot time — the UUID lookup happens after device enumeration, and in this minimal kernel configuration the timing or driver availability caused the resolution to fail.

**Solution**
Changed the root parameter to a direct device path:

```
options root=/dev/sdb1 rw nouveau.modeset=0 i915.modeset=0 module_blacklist=i915
```

This is less portable (device names can change if drives are added or removed) but reliable on a fixed hardware configuration. For a more robust solution, an initramfs with UUID support could be added later.

**Lesson**
UUID-based root identification requires either an initramfs or specific kernel configuration to work reliably. On a minimal LFS kernel without initramfs, direct device paths are more dependable.

---

## 3. No Console Output After Boot

**Symptom**
The system booted successfully (confirmed via SSH) but produced no output on the physically connected monitor. The display showed nothing after the UEFI splash screen.

**Root Cause**
The Intel i915 graphics driver exhibited initialization issues on this hardware. The kernel was configured with i915 support, but the driver failed to initialize the display pipeline correctly — likely due to the interaction with the disabled NVIDIA GPU and the specific Haswell-era integrated graphics configuration.

**Solution**
Disabled the i915 driver entirely via kernel command line parameters:

```
i915.modeset=0 module_blacklist=i915
```

The system was reconfigured for SSH-first (headless) administration. All subsequent interaction occurs over SSH. The display issue can be revisited later without impacting system functionality.

**Lesson**
Headless operation is the correct operational model for a server or infrastructure machine regardless of display availability. Treating the absence of a working display as a blocker is the wrong framing — SSH access is sufficient and often preferable.

---

## 4. WiFi Adapter Not Recognized

**Symptom**
After first boot, the TP-Link Archer T2U Plus (RTL8821AU chipset) was not recognized. `ip link` showed no wireless interface. `dmesg` showed no relevant USB device initialization.

**Root Cause**
The RTL8821AU chipset has no driver in the mainline Linux kernel tree. It requires an out-of-tree kernel module. This is a known gap — Realtek has not contributed this driver upstream, and it is maintained by third parties.

**Solution**
Compiled the RTL8821AU driver from the morrownr community repository against the custom kernel source:

```bash
git clone https://github.com/morrownr/8821au-20210708.git /sources/8821au-20210708
cd /sources/8821au-20210708
make -C /sources/linux-6.18.10 M=/sources/8821au-20210708 modules
make -C /sources/linux-6.18.10 M=/sources/8821au-20210708 modules_install
depmod -a 6.18.10
modprobe 88XXau
```

The driver was compiled inside the chroot against the LFS kernel source before first boot, and installed to the correct module path so it loaded automatically.

**Lesson**
Out-of-tree drivers require the kernel source tree (or at minimum the kernel headers) to be present at compile time. The kernel version must match exactly — a module compiled against 6.18.10 will not load on a different kernel version. This is why keeping the kernel source available post-build matters.

---

## 5. SSH Permission Denied

**Symptom**
After first boot, SSH connection attempts from another machine were rejected:

```
Permission denied (publickey).
```

**Root Cause**
OpenSSH 9.x changed the default configuration to disable password authentication. The LFS build includes a current OpenSSH version, which ships with `PasswordAuthentication no` as the effective default. Additionally, PAM integration was enabled but PAM was not configured on the minimal LFS system, causing further authentication failures.

**Solution**
Edited `/etc/ssh/sshd_config` to explicitly enable password authentication and disable PAM:

```
PasswordAuthentication yes
UsePAM no
PermitRootLogin yes
```

Restarted the SSH daemon:
```bash
systemctl restart sshd
```

**Security Note**
These settings are appropriate for a private lab environment. Before exposing this system to any network, disable root login, switch to key-based authentication only, and re-enable PAM with a proper configuration.

**Lesson**
Always explicitly configure sshd_config on a new system rather than relying on defaults — default behavior changes between OpenSSH versions and can vary by build configuration.

---

## 6. No IP Address After Boot

**Symptom**
SSH connection attempts timed out. The system booted and WiFi driver loaded, but no IP address was assigned. `ip addr` showed the wireless interface with no address.

**Root Cause**
systemd-networkd was not configured. The network interface existed but nothing was managing DHCP or the wireless association. wpa_supplicant was installed but not connected to an access point.

**Solution**
Two components were required:

**wpa_supplicant configuration** (`/etc/wpa_supplicant/wpa_supplicant-wlan0.conf`):
```
ctrl_interface=/run/wpa_supplicant
update_config=1

network={
    ssid="YourNetworkName"
    psk="YourPassword"
}
```

**systemd-networkd configuration** (`/etc/systemd/network/25-wireless.network`):
```
[Match]
Name=wlan0

[Network]
DHCP=yes
```

Enabled and started both services:
```bash
systemctl enable wpa_supplicant@wlan0
systemctl enable systemd-networkd
systemctl start wpa_supplicant@wlan0
systemctl start systemd-networkd
```

**Lesson**
On a systemd-based LFS system, network management requires both a wireless association daemon (wpa_supplicant) and a network configuration daemon (systemd-networkd). Neither works without the other for WiFi. Both must be explicitly enabled — systemd does not auto-configure networking.

---

## 7. GCC 15.x Defaulting to C23 Standard

**Symptom**
During Chapter 8 package compilation, several packages failed with errors related to implicit function declarations and other C23 incompatibilities. Packages that compiled cleanly on older GCC versions failed on GCC 15.2.0.

**Root Cause**
GCC 15.x changed the default C standard from gnu17 to C23. Several LFS packages were written to older C standards and relied on behaviors that C23 no longer permits (implicit function declarations, implicit int, etc.).

**Solution**
Set the C standard explicitly via CFLAGS before affected build steps:

```bash
export CFLAGS="-std=gnu17"
```

Applied selectively to packages that failed; left unset for packages that compiled cleanly under C23.

**Lesson**
When building against a very recent toolchain, be aware of default standard changes. GCC 15's C23 default will affect any package not explicitly targeting a C standard. The gnu17 flag restores the previous default behavior without sacrificing modern compiler optimizations.

---

## 8. ncurses Wide-Character Build Issues

**Symptom**
Several packages depending on ncurses (bash, vim, and others) failed to link correctly, with errors referencing missing wide-character symbols (`_nc_wacs`, `wget_wch`, etc.).

**Root Cause**
The ncurses build requires explicit flags to enable wide-character (Unicode) support. Without these flags, the resulting library lacks wide-character support, and packages that expect it fail to link.

**Solution**
Built ncurses with explicit wide-character flags:

```bash
./configure --prefix=/usr \
            --mandir=/usr/share/man \
            --with-shared \
            --without-debug \
            --without-normal \
            --with-cxx-shared \
            --enable-pc-files \
            --enable-widec \
            --with-pkg-config-libdir=/usr/lib/pkgconfig
```

The `--enable-widec` flag is the critical addition. A compatibility symlink was also required so packages looking for `libncurses.so` found the wide-character version:

```bash
ln -sv libncursesw.so /usr/lib/libncurses.so
```

**Lesson**
The LFS book covers this, but it is easy to miss or misconfigure. Always build ncurses with wide-character support enabled — the modern Linux software ecosystem assumes it.

---

*Last updated: May 2026*
*System: jbird — Intel i7-4790K, LFS 13.0 systemd, kernel 6.18.10*
