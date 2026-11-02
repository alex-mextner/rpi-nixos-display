# Киоск: cage (Wayland, одно приложение) + Chromium на весь экран.
{ config, lib, pkgs, ... }:
let
  browser = pkgs.writeShellScript "kiosk-browser" ''
    exec ${lib.getExe pkgs.chromium} \
      --kiosk \
      --ozone-platform=wayland \
      --noerrdialogs \
      --disable-infobars \
      --no-first-run \
      --check-for-update-interval=31536000 \
      --unsafely-treat-insecure-origin-as-secure="http://localhost" \
      ${lib.escapeShellArg config.rpi4.kiosk.url}
  '';
in
{
  users.users.kiosk = {
    isNormalUser = true;
    extraGroups = [
      "video"
      "render" # аппаратное 3D-ускорение GPU
    ];
  };

  services.cage = {
    enable = true;
    user = "kiosk";
    program = "${browser}";
    # -s: разрешить переключение VT, -d: без клиентских декораций окон
    extraArguments = [
      "-s"
      "-d"
    ];
    # Без клавиатуры/мыши wlroots иначе падает («no input devices»), и киоск не стартует.
    environment.WLR_LIBINPUT_NO_DEVICES = "1";
  };

  # Шрифты для обычных страниц (по умолчанию в NixOS шрифтов нет).
  fonts.enableDefaultPackages = true;

  systemd.services."cage-tty1" = {
    # Модуль cage ставит restartIfChanged=false: без этого смена URL не применялась бы до ребута.
    restartIfChanged = lib.mkForce true;
    # cage завершается вместе с Chromium: поднимаем киоск заново после падения браузера.
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = 5;
    };
  };
}
