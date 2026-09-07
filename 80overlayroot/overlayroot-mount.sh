#!/usr/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

overlayroot=$(getarg overlayroot=)
[ -z "$overlayroot" ] && return 0

info "overlayroot: setting up overlay with '$overlayroot'"

mkdir -m 0755 -p /run/overlayroot/ro
mount --bind "$NEWROOT" /run/overlayroot/ro
mount --make-private /run/overlayroot/ro
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
    resync_log=/run/overlayroot/rw/overlayroot.output
    ovl_log() { echo "$(date '+%H:%M:%S') $*" >> "$resync_log"; info "overlayroot: $*"; }

    ovl_log "resyncing upper to lower ..."

    resync_exclude="tmp var/tmp var/log overlayroot.resync"

    mount -o remount,rw /run/overlayroot/ro

    ovl_log "processing whiteouts ..."
    (cd /run/overlayroot/rw/upper && find . -type c -print) | while read path; do
        [ "$(stat -c '%t %T' "/run/overlayroot/rw/upper/$path")" = "0 0" ] || continue
        ovl_log "  whiteout: $path"
        rm -rf "/run/overlayroot/ro/$path" "/run/overlayroot/rw/upper/$path"
    done

    ovl_log "syncing upper to lower ..."
    rsync -aHAX -v $(printf -- '--exclude=%s ' $resync_exclude) \
        /run/overlayroot/rw/upper/ /run/overlayroot/ro/ >>"$resync_log" 2>&1
    rc=$?

    rm -f /run/overlayroot/ro/overlayroot.resync

    if [ "$rc" -ne 0 ]; then
        ovl_log "ERROR: rsync failed (exit $rc), keeping upper intact"
        mount -o remount,ro /run/overlayroot/ro
    else
        has_journal=0
        [ -d /run/overlayroot/rw/upper/var/log/journal ] && has_journal=1

        ovl_log "clearing upper ..."
        rm -rf /run/overlayroot/rw/upper
        mkdir /run/overlayroot/rw/upper

        if [ "$has_journal" -eq 1 ]; then
            ovl_log "recreating /var/log/journal for persistent journald"
            mkdir -p /run/overlayroot/rw/upper/var/log/journal
        fi

        touch /run/overlayroot/rw/upper/overlayroot.resynced

        mount -o remount,ro /run/overlayroot/ro

        ovl_log "resync complete"
    fi

    mv $resync_log /run/overlayroot/rw/upper
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
