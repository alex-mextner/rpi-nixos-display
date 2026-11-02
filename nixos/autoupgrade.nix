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
    persistent = true; # выключенная в 04:00 Pi догонит при включении
  };
}
