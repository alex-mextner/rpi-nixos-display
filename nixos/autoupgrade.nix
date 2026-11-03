# Автообновление: раз в сутки Pi сама забирает main из GitHub и делает switch.
# Без перезагрузки: изменения ядра/загрузчика вступают в силу при ближайшем ребуте.
{ config, ... }:
{
  system.autoUpgrade = {
    enable = true;
    flake = "github:${config.rpi4.repo}#rpi4";
    operation = "switch";
    allowReboot = false;
    dates = "04:00";
    randomizedDelaySec = "30min";
    persistent = true; # выключенная в 04:00 Pi догонит при включении (со случайной задержкой до 30 минут)
  };

  # Вычисление flake требует ~1–2 ГБ ОЗУ (на Pi 4 с 2 ГБ рядом с k3s и Chromium это риск OOM):
  # при нехватке памяти ядро должно убить обновление, а не киоск или k3s. Остальное прикрывает zram (hardware.nix).
  systemd.services.nixos-upgrade.serviceConfig = {
    OOMScoreAdjust = 1000;
    Nice = 19;
  };
}
