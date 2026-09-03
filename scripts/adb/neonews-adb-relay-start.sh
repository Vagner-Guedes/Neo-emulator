#!/system/bin/sh

# Android-x86 7.1-r5 exposes adbd through an IPv6 listener. Keep the
# host-facing QEMU port IPv4 and bridge it locally to adbd over IPv6.
setprop service.adb.tcp.port 5556
setprop persist.adb.tcp.port 5556
stop adbd
sleep 1
start adbd
sleep 1
/system/bin/app_process -Djava.class.path=/system/bin/adb-relay.dex /system/bin AdbIpv4Relay 5555 ::1 5556 &
