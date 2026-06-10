# overlayroot - Dracut module for overlay root filesystem

A dracut module that mounts the root filesystem as a read-only lower layer of an overlayfs, with all writes directed to a separate block device or tmpfs.

## Installation

Copy the module to the dracut modules directory and ensure it is included in future initramfs builds:

```bash
cp -r 80overlayroot /usr/lib/dracut/modules.d/
echo 'add_dracutmodules+=" overlayroot "' > /etc/dracut.conf.d/overlayroot.conf
dracut -f
```

## Kernel command line parameters

| Parameter | Description |
| --- | --- |
| `overlayroot=LABEL=<label>` | Use the filesystem with the given label as the persistent upper layer |
| `overlayroot=UUID=<uuid>` | Use the filesystem with the given UUID as the persistent upper layer |
| `overlayroot=/dev/<device>` | Use the given block device as the persistent upper layer |
| `overlayroot=tmpfs` | Use tmpfs as the upper layer (ephemeral, all changes lost on reboot) |
| `overlayroot.timeout=<seconds>` | Time to wait for the upper layer device to appear (default: 10) |
| `overlayroot.resync` | One-shot: resync upper layer changes to lower before mounting overlay |

## Mount layout

When active, the following mounts are set up:

| Path | Description |
| --- | --- |
| `/run/overlayroot/ro` | Read-only bind mount of the real root filesystem (lower layer) |
| `/run/overlayroot/rw` | Mount point for the upper layer device (or tmpfs) |
| `/run/overlayroot/rw/upper` | Overlayfs upper directory |
| `/run/overlayroot/rw/work` | Overlayfs work directory |
| `/` | Overlayfs merging lower and upper |

## GRUB / BLS setup

Create a Boot Loader Specification entry with `overlayroot=` appended to the options. For example, copy the existing entry and add the parameter:

```
title Fedora Linux 45 (Overlay Root)
version 7.1.0+overlayroot
linux /vmlinuz-7.1.0
initrd /initramfs-7.1.0.img
options root=UUID=<root-uuid> ro rhgb quiet overlayroot=LABEL=DISK2_ROOT
```

The normal boot entry remains untouched, allowing you to choose at the GRUB menu.

## tmpfs fallback

If the specified block device is not found after the timeout (default 10 seconds), or if `overlayroot=tmpfs` is used, the upper layer falls back to tmpfs. In this mode, `/etc/motd` is populated with a warning:

```
*********************************************
* Root filesystem is on a tmpfs overlay.    *
* All changes are EPHEMERAL and will be     *
* lost on reboot.                           *
*********************************************
```

## Resyncing upper to lower

The resync feature merges all changes from the upper layer back into the real root filesystem. This is useful to "commit" overlay changes permanently.

### Triggering a resync

Either method works:

1. **File trigger** (from the running system):
   ```bash
   touch /overlayroot.resync
   reboot
   ```

2. **Kernel parameter** (one-shot, at the GRUB prompt):
   Add `overlayroot.resync` to the boot command line.

### What resync does

During early boot (in the initramfs, before the overlay is assembled):

1. Remounts the lower filesystem read-write
2. Deletes files from lower that have been whited out (deleted) in upper
3. Deletes files from lower that exist in upper (will be replaced)
4. Copies all files from upper to lower, preserving extended attributes (including SELinux labels)
5. Clears the upper layer
6. If `/var/log/journal` existed in the upper layer, recreates it so that persistent journald logging (`Storage=auto`) continues to work
7. Remounts the lower filesystem read-only
8. Drops a `/overlayroot.resynced` marker in the upper layer

Temporary and log files are excluded from the resync to avoid polluting the lower filesystem with transient data. The excluded paths are: `/tmp`, `/var/tmp`, `/var/log`.

### Post-resync SELinux relabel

Files written to the upper layer by initramfs services (e.g. in `/var/log`) during switch-root lack proper SELinux labels. A systemd oneshot service (`overlayroot-relabel.service`) runs early in `sysinit.target` when the `/overlayroot.resynced` marker is present:

- Relabels all files in the upper layer using `restorecon -i -F`
- Deletes the marker file

## SELinux integration

The module automatically configures SELinux for overlay operation on each boot:

- **`file_contexts.subs`**: Adds an equivalency mapping `/run/overlayroot/rw/upper` to `/`, so `restorecon` applies the correct policy to files in the upper layer.
- **`fixfiles_exclude_dirs`**: Excludes `/run/overlayroot` from full-system relabeling (`fixfiles`), preventing interference with overlay internals.

## Files

```
/usr/lib/dracut/modules.d/80overlayroot/
    module-setup.sh          # Module installation and dependencies
    overlayroot-mount.sh     # Pre-pivot hook: sets up overlay, resync, SELinux
/etc/dracut.conf.d/
    overlayroot.conf         # Ensures module is included in initramfs
```
