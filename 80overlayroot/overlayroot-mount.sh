#!/usr/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

overlayroot=$(getarg overlayroot=)
[ -z "$overlayroot" ] && return 0

info "overlayroot: setting up overlay with '$overlayroot'"

mkdir -m 0755 -p /run/overlayroot/ro
mount --bind "$NEWROOT" /run/overlayroot/ro
mount -o remount,ro /run/overlayroot/ro

use_tmpfs=0

case "$overlayroot" in
    tmpfs)
        use_tmpfs=1
        ;;
    LABEL=*)
        dev="/dev/disk/by-label/${overlayroot#LABEL=}"
        ;;
    UUID=*)
        dev="/dev/disk/by-uuid/${overlayroot#UUID=}"
        ;;
    *)
        dev="$overlayroot"
        ;;
esac

mkdir -m 0755 -p /run/overlayroot/rw

if [ "$use_tmpfs" -eq 0 ]; then
    timeout=$(getarg overlayroot.timeout=)
    timeout=${timeout:-10}

    if ! [ -b "$dev" ]; then
        info "overlayroot: waiting up to ${timeout}s for $dev"
        waited=0
        while ! [ -b "$dev" ] && [ "$waited" -lt "$timeout" ]; do
            sleep 1
            waited=$((waited + 1))
        done
    fi

    if [ -b "$dev" ]; then
        if mount "$dev" /run/overlayroot/rw; then
            info "overlayroot: mounted $dev as upper layer (persistent)"
        else
            warn "overlayroot: failed to mount $dev, falling back to tmpfs"
            use_tmpfs=1
        fi
    else
        warn "overlayroot: device $dev not found after ${timeout}s, falling back to tmpfs"
        use_tmpfs=1
    fi
fi

if [ "$use_tmpfs" -eq 1 ]; then
    mount -t tmpfs tmpfs /run/overlayroot/rw
    info "overlayroot: using tmpfs as upper layer (ephemeral)"
fi

mkdir -m 0755 -p /run/overlayroot/rw/upper
mkdir -m 0755 -p /run/overlayroot/rw/work

resync=0
if [ "$use_tmpfs" -eq 0 ]; then
    if getargbool 0 overlayroot.resync || [ -e /run/overlayroot/rw/upper/overlayroot.resync ]; then
        resync=1
    fi
fi

if [ "$resync" -eq 1 ]; then
    info "overlayroot: resyncing upper to lower ..."

    resync_exclude="./tmp ./var/tmp ./var/log"

    mount -o remount,rw /run/overlayroot/ro

    info "overlayroot: deleting whiteouts from lower ..."
    (cd /run/overlayroot/rw/upper && find . -type c -print) | while read path; do
        [ "$(stat -c '%t %T' "/run/overlayroot/rw/upper/$path")" = "0 0" ] || continue
        rm -rf "/run/overlayroot/ro/$path" "/run/overlayroot/rw/upper/$path"
    done

    info "overlayroot: deleting modified files from lower ..."
    (cd /run/overlayroot/rw/upper && find . ! -type d $(printf -- '-not -path %s* ' $resync_exclude) -print0) | (cd /run/overlayroot/ro && xargs -0 rm -rf)

    info "overlayroot: copying upper to lower ..."
    (cd /run/overlayroot/rw/upper && tar --xattrs --xattrs-include='*' $(printf -- '--exclude=%s ' $resync_exclude) -cf - .) | (cd /run/overlayroot/ro && tar --xattrs --xattrs-include='*' -xf -)

    rm -f /run/overlayroot/ro/overlayroot.resync

    has_journal=0
    [ -d /run/overlayroot/rw/upper/var/log/journal ] && has_journal=1

    info "overlayroot: clearing upper ..."
    rm -rf /run/overlayroot/rw/upper/* /run/overlayroot/rw/upper/.*

    if [ "$has_journal" -eq 1 ]; then
        info "overlayroot: recreating /var/log/journal for persistent journald"
        mkdir -p /run/overlayroot/rw/upper/var/log/journal
    fi

    touch /run/overlayroot/rw/upper/overlayroot.resynced

    mount -o remount,ro /run/overlayroot/ro

    info "overlayroot: resync complete"
fi

mount -t overlay overlay \
    -o lowerdir=/run/overlayroot/ro,upperdir=/run/overlayroot/rw/upper,workdir=/run/overlayroot/rw/work \
    "$NEWROOT"

if [ "$use_tmpfs" -eq 1 ]; then
    mkdir -p "$NEWROOT/etc"
    cat > "$NEWROOT/etc/motd" <<'EOF'
*********************************************
* Root filesystem is on a tmpfs overlay.    *
* All changes are EPHEMERAL and will be     *
* lost on reboot.                           *
*********************************************
EOF
fi

# Exclude overlay internals from fixfiles relabeling
excludefile="$NEWROOT/etc/selinux/fixfiles_exclude_dirs"
grep -qsxF '/run/overlayroot' "$excludefile" 2>/dev/null || echo '/run/overlayroot' >> "$excludefile"

# SELinux equivalency so restorecon maps overlay paths to / policy rules
subsfile="$NEWROOT/etc/selinux/targeted/contexts/files/file_contexts.subs"
grep -qsF '/run/overlayroot/rw/upper' "$subsfile" 2>/dev/null || echo '/run/overlayroot/rw/upper /' >> "$subsfile"

# Oneshot service to relabel upper layer files written during initramfs (post-resync)
mkdir -p "$NEWROOT/etc/systemd/system/sysinit.target.wants"
cat > "$NEWROOT/etc/systemd/system/overlayroot-relabel.service" <<'EOF'
[Unit]
Description=Relabel overlay upper layer for SELinux after resync
DefaultDependencies=no
ConditionPathExists=/overlayroot.resynced
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'find /run/overlayroot/rw/upper -xdev -print0 | xargs -0 restorecon -i -F'
ExecStartPost=/bin/rm -f /overlayroot.resynced
EOF
ln -sf ../overlayroot-relabel.service "$NEWROOT/etc/systemd/system/sysinit.target.wants/"
