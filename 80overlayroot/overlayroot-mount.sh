#!/usr/bin/sh

command -v getarg > /dev/null || . /lib/dracut-lib.sh

overlayroot=$(getarg overlayroot=)
[ -z "$overlayroot" ] && return 0

info "overlayroot: setting up overlay with '$overlayroot'"

basedir="/run/overlayroot"
lower="$basedir/ro"
baserw="$basedir/rw"

upper="$baserw/upper"
work="$baserw/work"

mkdir -m 0755 -p $lower
mount --bind "$NEWROOT" $lower
mount --make-private $lower
mount -o remount,ro $lower

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

mkdir -m 0755 -p $baserw

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
        if mount "$dev" $baserw; then
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
    mount -t tmpfs tmpfs $baserw
    info "overlayroot: using tmpfs as upper layer (ephemeral)"
fi

mkdir -m 0755 -p $upper
mkdir -m 0755 -p $work

resync=0
if [ "$use_tmpfs" -eq 0 ]; then
    if getargbool 0 overlayroot.resync || [ -e "$upper/overlayroot.resync" ]; then
        resync=1
    fi
fi

if [ "$resync" -eq 1 ]; then

    tmpstore="$baserw/tmp"

    resync_logname="overlayroot.output"
    # Log is stored outside of upper initially to avoid being deleted
    resync_log="$baserw/$resync_logname"

    rm -f $resync_log

    ovl_log() { echo "$(date '+%H:%M:%S') $*" >> "$resync_log"; info "overlayroot: $*"; }

    ovl_log "resyncing upper to lower ..."

    resync_exclude=(
        /tmp /var/tmp /var/log
        /overlayroot.resync /$resync_logname
        /etc/systemd/journald.conf.d/usb.conf
        /.autorelabel /etc/selinux/config
    )

    mount -o remount,rw $lower

    ovl_log "processing whiteouts ..."
    (cd $upper && find . -type c -print) | while read path; do
        [ "$(stat -c '%t %T' "$upper/$path")" = "0 0" ] || continue
        ovl_log "  whiteout: $path"
        rm -rf "$lower/$path" "$upper/$path"
    done

    ovl_log "syncing upper to lower ..."
    rsync -aHAXX -v $(printf -- '--exclude=%s ' ${resync_exclude[@]}) \
        $upper/ $lower/ >>"$resync_log" 2>&1
    rc=$?

    rm -f $lower/overlayroot.resync

    if [ "$rc" -ne 0 ]; then
        ovl_log "ERROR: rsync failed (exit $rc), keeping upper intact"
        mount -o remount,ro $lower
    else

        expand_paths() {
            awk '{
                for (i = 1; i <= NF; i++) {
                    n = split($i, parts, "/")
                    path = ""
                    for (j = 2; j <= n; j++) {
                        path = path "/" parts[j]
                        printf "%s%s", path, (i == NF && j == n ? ORS : " ")
                    }
                }
            }' "${@:--}"
        }

        ovl_log "copying persistent files to temporary storage ..."
        mkdir -p $tmpstore
        persistent_files=( /etc/systemd/journald.conf.d/usb.conf )
        expanded_paths=$(expand_paths <<< ${persistent_files[@]})
        rsync -aHAXX -v $(printf -- '--include=%s ' $expanded_paths) --exclude='*' \
            $upper/ $tmpstore/ >>"$resync_log" 2>&1

        ovl_log "clearing upper ..."
        rm -rf $upper
        mkdir $upper

        ovl_log "restoring persistent files on upper ..."
        rsync -aHAXX -v $(printf -- '--include=%s ' $expanded_paths) --exclude='*' \
            $tmpstore/ $upper/ >>"$resync_log" 2>&1
        rm -rf $tmpstore

        # Amend /etc/selinux/config on upper to relabel in Permissive
        selinux_includes=( /etc/selinux/config )
        expanded_paths=$(expand_paths <<< ${selinux_includes[@]})
        ovl_log "copying lower /etc/selinux/config to upper ..."
        rsync -aHAXX -v $(printf -- '--include=%s ' $expanded_paths) --exclude='*' \
            $lower/ $upper/ >>"$resync_log" 2>&1
        ovl_log "changing to Permissive and forcing a relabel ..."
        sed -i "s/^SELINUX=enforcing/SELINUX=permissive/" $upper/etc/selinux/config
        echo "-v" > $upper/.autorelabel

        mount -o remount,ro $lower

        ovl_log "resync complete"

    fi

    mv $resync_log "$upper/$resync_logname"
fi

mount -t overlay overlay -o xino=on,lowerdir=$lower,upperdir=$upper,workdir=$work "$NEWROOT"

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
grep -qsxF "$basedir" "$excludefile" 2>/dev/null || echo "$basedir" >> "$excludefile"

# SELinux equivalency so restorecon maps overlay paths to / policy rules
subsfile="$NEWROOT/etc/selinux/targeted/contexts/files/file_contexts.subs"
grep -qsF "$upper" "$subsfile" 2>/dev/null || echo "$upper /" >> "$subsfile"
grep -qsF "$lower" "$subsfile" 2>/dev/null || echo "$lower /" >> "$subsfile"
