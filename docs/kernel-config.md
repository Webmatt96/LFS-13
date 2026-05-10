# Kernel Configuration — Linux 6.18.10 (jbird)

This document explains the kernel configuration decisions made for the jbird LFS build. The configuration was produced via `make defconfig` as a baseline, then refined through `make menuconfig` to address specific hardware requirements.

The canonical config file is at `kernel/config-6.18.10` in this repository.

---

## Hardware Context

| Component | Details | Driver Implications |
|-----------|---------|-------------------|
| CPU | Intel Core i7-4790K (Haswell) | x86_64, no special requirements |
| Integrated GPU | Intel HD Graphics 4600 | i915 driver (disabled — see below) |
| Discrete GPU | NVIDIA GeForce GTX 970 | nouveau driver (disabled) |
| WiFi | TP-Link Archer T2U Plus (RTL8821AU) | Out-of-tree module required |
| USB | xHCI (USB 3.0), EHCI (USB 2.0) | Built-in |
| Boot firmware | UEFI | EFI stub required |

---

## Key Configuration Decisions

### GPU — Both GPUs Disabled

**Setting:**
```
CONFIG_DRM_NOUVEAU=n
CONFIG_DRM_I915=n
```

**Kernel command line:**
```
nouveau.modeset=0 i915.modeset=0 module_blacklist=i915
```

**Rationale:**
The NVIDIA GTX 970 requires either the proprietary NVIDIA driver (not appropriate for a minimal LFS system) or the nouveau driver, which depends on firmware blobs not present in the kernel tree. Enabling nouveau without firmware results in a non-functional GPU that can destabilize boot.

The Intel i915 driver exhibited initialization failures on this hardware — likely related to the dual-GPU configuration and Haswell-specific quirks. Rather than debugging a display driver on a system intended for headless server operation, both GPUs were disabled. The system runs entirely over SSH with no display dependency.

This is not a limitation in practice. Headless operation is the correct model for infrastructure machines.

---

### EFI Framebuffer

**Setting:**
```
CONFIG_FB_EFI=y
CONFIG_FRAMEBUFFER_CONSOLE=y
```

**Rationale:**
Even with both GPU drivers disabled, the EFI framebuffer allows the kernel to use the display output established by the UEFI firmware during early boot. This provides a minimal console if needed without requiring a full GPU driver stack. It also ensures the kernel doesn't panic looking for a console device.

---

### WiFi Subsystem

**Settings:**
```
CONFIG_CFG80211=y
CONFIG_MAC80211=y
CONFIG_WIRELESS=y
```

**Rationale:**
The RTL8821AU driver is an out-of-tree module — it is not compiled into the kernel. However, it depends on the cfg80211 and mac80211 wireless subsystem being present in the kernel. These must be built-in (or as modules that load before the driver) for the RTL8821AU module to load successfully.

The driver itself is compiled separately against the kernel source tree:
```bash
make -C /sources/linux-6.18.10 M=/sources/8821au-20210708 modules
```

---

### USB Host Controllers

**Settings:**
```
CONFIG_USB_XHCI_HCD=y    # USB 3.0
CONFIG_USB_EHCI_HCD=y    # USB 2.0
CONFIG_USB_OHCI_HCD=y    # USB 1.1 (legacy)
CONFIG_USB_UHCI_HCD=y    # USB 1.1 (Intel legacy)
```

**Rationale:**
The RTL8821AU adapter connects via USB. All USB host controller variants are enabled to ensure the adapter is recognized regardless of which physical port it occupies. The Haswell-era Z97 chipset uses xHCI for USB 3.0 ports and EHCI for USB 2.0 ports.

---

### EFI Boot Stub

**Setting:**
```
CONFIG_EFI_STUB=y
CONFIG_EFI=y
```

**Rationale:**
Required for systemd-boot to load the kernel directly as a UEFI application. Without EFI stub support, the kernel cannot be launched by a UEFI bootloader without an intermediary like GRUB. Since this build uses systemd-boot, EFI stub is mandatory.

---

### Firmware Loader

**Settings:**
```
CONFIG_FW_LOADER=y
CONFIG_FW_LOADER_USER_HELPER=y
CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y
```

**Rationale:**
Required for the system to load firmware blobs for hardware that needs them. Also a dependency for several driver subsystems even when the firmware itself is not present.

---

### Filesystem Support

**Settings:**
```
CONFIG_EXT4_FS=y         # Root filesystem
CONFIG_VFAT_FS=y         # EFI system partition (FAT32)
CONFIG_TMPFS=y           # Required by systemd
CONFIG_PROC_FS=y         # Required by virtually everything
CONFIG_SYSFS=y           # Required by udev/systemd
```

**Rationale:**
ext4 is the root filesystem. VFAT is required to read the EFI system partition where the bootloader and kernel image live. tmpfs, procfs, and sysfs are mandatory for systemd operation.

---

### systemd Requirements

systemd has a non-trivial set of kernel configuration requirements. Key items enabled:

```
CONFIG_CGROUPS=y
CONFIG_INOTIFY_USER=y
CONFIG_SIGNALFD=y
CONFIG_TIMERFD=y
CONFIG_EPOLL=y
CONFIG_NET=y
CONFIG_UNIX=y
CONFIG_INET=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
```

**Rationale:**
`DEVTMPFS` and `DEVTMPFS_MOUNT` are particularly important — they allow the kernel to populate `/dev` automatically at boot before udev takes over, which is required for early boot to succeed on a systemd system.

---

## What Was Intentionally Excluded

| Feature | Reason |
|---------|--------|
| initramfs/initrd | Not needed; direct device path used for root |
| Sound subsystem (ALSA/OSS) | Headless server, no audio required |
| Bluetooth | Not needed for this build |
| IPv6 | Not configured; can be added later |
| Loadable module signing | Lab environment; simplifies out-of-tree driver loading |
| NVIDIA/nouveau | No firmware available; system runs headless |
| Intel i915 display | Initialization issues; system runs headless |

---

## Build Process

```bash
cd /sources/linux-6.18.10

# Start from a sane baseline
make defconfig

# Refine for hardware requirements
make menuconfig

# Compile (use all available cores)
make -j$(nproc)

# Install modules
make modules_install

# Install kernel image
cp -iv arch/x86/boot/bzImage /boot/vmlinuz-6.18.10-lfs
cp -iv System.map /boot/System.map-6.18.10
```

Total compile time on the i7-4790K (8 threads): approximately 20-30 minutes.

---

## Kernel Command Line

Final boot parameters as written in `/boot/loader/entries/lfs.conf`:

```
root=/dev/sdb1 rw nouveau.modeset=0 i915.modeset=0 module_blacklist=i915
```

| Parameter | Purpose |
|-----------|---------|
| `root=/dev/sdb1` | Direct device path to LFS root partition |
| `rw` | Mount root read-write on boot |
| `nouveau.modeset=0` | Disable NVIDIA GPU modesetting |
| `i915.modeset=0` | Disable Intel GPU modesetting |
| `module_blacklist=i915` | Prevent i915 module from loading entirely |

---

*Last updated: May 2026*
*System: jbird — Intel i7-4790K, LFS 13.0 systemd, kernel 6.18.10*
