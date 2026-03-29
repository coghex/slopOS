#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:?missing target dir}"
BUSYBOX_BIN="$TARGET_DIR/bin/busybox"
removed=0

prune_busybox_link() {
  local target="$1"

  if [[ ! -L "$target" ]]; then
    return 0
  fi

  if [[ "$(readlink -f "$target")" != "$BUSYBOX_BIN" ]]; then
    return 0
  fi

  rm -f "$target"
  ((removed += 1))
}

prune_any_busybox_link() {
  local target="$1"

  if [[ ! -L "$target" ]]; then
    return 0
  fi

  if [[ "$(readlink -f "$target")" != "$BUSYBOX_BIN" ]]; then
    return 0
  fi

  rm -f "$target"
  ((removed += 1))
}

for target in \
  "$TARGET_DIR/bin/arch" \
  "$TARGET_DIR/bin/ash" \
  "$TARGET_DIR/bin/base32" \
  "$TARGET_DIR/bin/chattr" \
  "$TARGET_DIR/bin/cpio" \
  "$TARGET_DIR/bin/dmesg" \
  "$TARGET_DIR/bin/dumpkmap" \
  "$TARGET_DIR/bin/free" \
  "$TARGET_DIR/bin/fdflush" \
  "$TARGET_DIR/bin/getopt" \
  "$TARGET_DIR/usr/bin/less" \
  "$TARGET_DIR/bin/linux32" \
  "$TARGET_DIR/bin/linux64" \
  "$TARGET_DIR/bin/lsattr" \
  "$TARGET_DIR/bin/more" \
  "$TARGET_DIR/bin/mt" \
  "$TARGET_DIR/bin/nuke" \
  "$TARGET_DIR/bin/ping" \
  "$TARGET_DIR/bin/pipe_progress" \
  "$TARGET_DIR/bin/resume" \
  "$TARGET_DIR/bin/run-parts" \
  "$TARGET_DIR/bin/setpriv" \
  "$TARGET_DIR/bin/setserial" \
  "$TARGET_DIR/bin/setarch" \
  "$TARGET_DIR/bin/su" \
  "$TARGET_DIR/bin/usleep" \
  "$TARGET_DIR/bin/vi" \
  "$TARGET_DIR/usr/bin/which" \
  "$TARGET_DIR/usr/bin/telnet" \
  "$TARGET_DIR/usr/bin/traceroute" \
  "$TARGET_DIR/usr/bin/nslookup" \
  "$TARGET_DIR/usr/bin/bc" \
  "$TARGET_DIR/usr/bin/[[" \
  "$TARGET_DIR/usr/bin/ascii" \
  "$TARGET_DIR/usr/bin/chrt" \
  "$TARGET_DIR/usr/bin/chvt" \
  "$TARGET_DIR/usr/bin/clear" \
  "$TARGET_DIR/usr/bin/crc32" \
  "$TARGET_DIR/usr/bin/dc" \
  "$TARGET_DIR/usr/bin/deallocvt" \
  "$TARGET_DIR/usr/bin/dos2unix" \
  "$TARGET_DIR/usr/bin/eject" \
  "$TARGET_DIR/usr/bin/fallocate" \
  "$TARGET_DIR/usr/bin/flock" \
  "$TARGET_DIR/usr/bin/fuser" \
  "$TARGET_DIR/bin/gzip" \
  "$TARGET_DIR/bin/gunzip" \
  "$TARGET_DIR/bin/zcat" \
  "$TARGET_DIR/usr/bin/getfattr" \
  "$TARGET_DIR/usr/bin/hexedit" \
  "$TARGET_DIR/usr/bin/hexdump" \
  "$TARGET_DIR/usr/bin/ipcrm" \
  "$TARGET_DIR/usr/bin/ipcs" \
  "$TARGET_DIR/usr/bin/killall" \
  "$TARGET_DIR/usr/bin/last" \
  "$TARGET_DIR/usr/bin/logger" \
  "$TARGET_DIR/usr/bin/lsof" \
  "$TARGET_DIR/usr/bin/lspci" \
  "$TARGET_DIR/usr/bin/lsscsi" \
  "$TARGET_DIR/usr/bin/lsusb" \
  "$TARGET_DIR/usr/bin/lzopcat" \
  "$TARGET_DIR/usr/bin/mesg" \
  "$TARGET_DIR/usr/bin/microcom" \
  "$TARGET_DIR/usr/bin/mkpasswd" \
  "$TARGET_DIR/usr/bin/openvt" \
  "$TARGET_DIR/usr/bin/renice" \
  "$TARGET_DIR/usr/bin/resize" \
  "$TARGET_DIR/usr/bin/reset" \
  "$TARGET_DIR/usr/bin/setfattr" \
  "$TARGET_DIR/usr/bin/setkeycodes" \
  "$TARGET_DIR/usr/bin/setsid" \
  "$TARGET_DIR/usr/bin/sha3sum" \
  "$TARGET_DIR/usr/bin/svc" \
  "$TARGET_DIR/usr/bin/svok" \
  "$TARGET_DIR/usr/bin/tftp" \
  "$TARGET_DIR/usr/bin/crontab" \
  "$TARGET_DIR/usr/bin/time" \
  "$TARGET_DIR/usr/bin/ts" \
  "$TARGET_DIR/usr/bin/tree" \
  "$TARGET_DIR/usr/bin/unix2dos" \
  "$TARGET_DIR/usr/bin/unlzop" \
  "$TARGET_DIR/usr/bin/unzip" \
  "$TARGET_DIR/usr/bin/uudecode" \
  "$TARGET_DIR/usr/bin/uuencode" \
  "$TARGET_DIR/usr/bin/uptime" \
  "$TARGET_DIR/usr/bin/vlock" \
  "$TARGET_DIR/usr/bin/xxd" \
  "$TARGET_DIR/usr/sbin/addgroup" \
  "$TARGET_DIR/usr/sbin/adduser" \
  "$TARGET_DIR/usr/sbin/delgroup" \
  "$TARGET_DIR/usr/sbin/deluser" \
  "$TARGET_DIR/usr/sbin/dnsd" \
  "$TARGET_DIR/usr/sbin/ether-wake" \
  "$TARGET_DIR/usr/sbin/fbset" \
  "$TARGET_DIR/usr/sbin/fdformat" \
  "$TARGET_DIR/usr/sbin/fsfreeze" \
  "$TARGET_DIR/usr/sbin/i2cdetect" \
  "$TARGET_DIR/usr/sbin/i2cdump" \
  "$TARGET_DIR/usr/sbin/i2cget" \
  "$TARGET_DIR/usr/sbin/i2cset" \
  "$TARGET_DIR/usr/sbin/i2ctransfer" \
  "$TARGET_DIR/usr/sbin/inetd" \
  "$TARGET_DIR/usr/sbin/loadfont" \
  "$TARGET_DIR/usr/sbin/mim" \
  "$TARGET_DIR/usr/sbin/nologin" \
  "$TARGET_DIR/usr/sbin/partprobe" \
  "$TARGET_DIR/usr/sbin/rdate" \
  "$TARGET_DIR/usr/sbin/readprofile" \
  "$TARGET_DIR/usr/sbin/setlogcons" \
  "$TARGET_DIR/usr/sbin/ubirename"
do
  prune_busybox_link "$target"
done

for target in \
  "$TARGET_DIR/bin/top" \
  "$TARGET_DIR/bin/ps" \
  "$TARGET_DIR/bin/w" \
  "$TARGET_DIR/bin/watch" \
  "$TARGET_DIR/bin/hostname" \
  "$TARGET_DIR/bin/mount" \
  "$TARGET_DIR/bin/mountpoint" \
  "$TARGET_DIR/bin/umount" \
  "$TARGET_DIR/sbin/fdisk" \
  "$TARGET_DIR/sbin/blkid" \
  "$TARGET_DIR/sbin/devmem" \
  "$TARGET_DIR/sbin/freeramdisk" \
  "$TARGET_DIR/sbin/fsck" \
  "$TARGET_DIR/sbin/fstrim" \
  "$TARGET_DIR/sbin/getty" \
  "$TARGET_DIR/sbin/hdparm" \
  "$TARGET_DIR/sbin/hwclock" \
  "$TARGET_DIR/sbin/ifdown" \
  "$TARGET_DIR/sbin/ifup" \
  "$TARGET_DIR/sbin/insmod" \
  "$TARGET_DIR/sbin/ip" \
  "$TARGET_DIR/sbin/ipaddr" \
  "$TARGET_DIR/sbin/iplink" \
  "$TARGET_DIR/sbin/ipneigh" \
  "$TARGET_DIR/sbin/iproute" \
  "$TARGET_DIR/sbin/iprule" \
  "$TARGET_DIR/sbin/iptunnel" \
  "$TARGET_DIR/sbin/klogd" \
  "$TARGET_DIR/sbin/loadkmap" \
  "$TARGET_DIR/sbin/lsmod" \
  "$TARGET_DIR/sbin/losetup" \
  "$TARGET_DIR/sbin/makedevs" \
  "$TARGET_DIR/sbin/mke2fs" \
  "$TARGET_DIR/sbin/mkdosfs" \
  "$TARGET_DIR/sbin/mkswap" \
  "$TARGET_DIR/sbin/mdev" \
  "$TARGET_DIR/sbin/modprobe" \
  "$TARGET_DIR/sbin/pivot_root" \
  "$TARGET_DIR/sbin/start-stop-daemon" \
  "$TARGET_DIR/sbin/run-init" \
  "$TARGET_DIR/sbin/runlevel" \
  "$TARGET_DIR/sbin/rmmod" \
  "$TARGET_DIR/sbin/setconsole" \
  "$TARGET_DIR/sbin/sulogin" \
  "$TARGET_DIR/sbin/swapoff" \
  "$TARGET_DIR/sbin/swapon" \
  "$TARGET_DIR/sbin/switch_root" \
  "$TARGET_DIR/sbin/sysctl" \
  "$TARGET_DIR/sbin/syslogd" \
  "$TARGET_DIR/sbin/uevent" \
  "$TARGET_DIR/sbin/udhcpc" \
  "$TARGET_DIR/sbin/vconfig" \
  "$TARGET_DIR/sbin/watchdog" \
  "$TARGET_DIR/usr/sbin/killall5" \
  "$TARGET_DIR/usr/sbin/crond"
do
  prune_any_busybox_link "$target"
done

prune_any_busybox_link "$TARGET_DIR/linuxrc"

if [[ -e "$BUSYBOX_BIN" || -L "$BUSYBOX_BIN" ]]; then
  rm -f "$BUSYBOX_BIN"
  ((removed += 1))
fi

if [[ -x "$TARGET_DIR/usr/sbin/ifup" ]]; then
  ln -snf /usr/sbin/ifup "$TARGET_DIR/sbin/ifup"
fi

if [[ -e "$TARGET_DIR/usr/sbin/ifdown" || -L "$TARGET_DIR/usr/sbin/ifdown" ]]; then
  ln -snf /usr/sbin/ifdown "$TARGET_DIR/sbin/ifdown"
fi

if [[ -x "$TARGET_DIR/sbin/agetty" ]]; then
  ln -snf /sbin/agetty "$TARGET_DIR/sbin/getty"
fi

if [[ -f "$TARGET_DIR/etc/shells" ]] && grep -qx '/bin/ash' "$TARGET_DIR/etc/shells"; then
  grep -vx '/bin/ash' "$TARGET_DIR/etc/shells" > "$TARGET_DIR/etc/shells.tmp"
  mv "$TARGET_DIR/etc/shells.tmp" "$TARGET_DIR/etc/shells"
fi

if [[ -x "$TARGET_DIR/sbin/syslogd" && ! -e "$TARGET_DIR/sbin/klogd" ]]; then
  rm -f "$TARGET_DIR/etc/init.d/S02klogd"
fi

if [[ -x "$TARGET_DIR/usr/sbin/crond" ]]; then
  rm -f "$TARGET_DIR/etc/init.d/S50crond"
fi

if (( removed > 0 )); then
  echo "Pruned $removed stale BusyBox paths from seed image"
fi
