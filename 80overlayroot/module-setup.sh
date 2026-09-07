#!/usr/bin/bash

check() {
    require_kernel_modules overlay || return 1
    return 255
}

depends() {
    echo base
}

installkernel() {
    hostonly="" instmods overlay
}

install() {
    inst_multiple mount mkdir sleep stat find rm rsync xargs touch grep cat ln date
    inst_hook pre-pivot 20 "$moddir/overlayroot-mount.sh"
}
