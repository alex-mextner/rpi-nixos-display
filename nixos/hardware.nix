# Чистое (pure) описание железа Raspberry Pi 4: hardware-configuration.nix из
# /etc/nixos во flake использовать нельзя (он impure), поэтому берём тот же
# модуль nixpkgs, из которого собран образ на SD: sd-image-aarch64.
# Он задаёт: ядро mainline, U-Boot + extlinux, fileSystems по меткам
# NIXOS_SD (/) и FIRMWARE (/boot/firmware, noauto), расширение раздела при первом буте.
{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/installer/sd-card/sd-image-aarch64.nix" ];

  # Прошивки Wi-Fi (brcmfmac) и т.п. — как в исходном образе.
  hardware.enableRedistributableFirmware = true;

  # Графика VideoCore VI (Mesa v3d/vc4) для Chromium под Wayland.
  hardware.graphics.enable = true;

  # ZFS не используется; явное значение убирает предупреждение nixpkgs 26.05.
  boot.zfs.forceImportRoot = false;

  boot.kernelParams = [
    # HDMI не гаснет через 10 минут и подаёт сигнал, даже если монитор включили позже
    "consoleblank=0"
    "video=HDMI-A-1:1920x1080M@60D"
    # cgroup-параметры для k3s на Raspberry Pi
    "cgroup_enable=cpuset"
    "cgroup_memory=1"
    "cgroup_enable=memory"
  ];
}
