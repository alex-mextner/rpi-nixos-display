# Единственное место с «ручками»: всё, что обычно правят, — опции rpi4.*.
# Значения выставляются в default.nix (раздел «Настройки»).
{ lib, ... }:
{
  options.rpi4 = {
    repo = lib.mkOption {
      type = lib.types.str;
      default = "alex-mextner/rpi-nixos-display";
      description = "GitHub-репозиторий (owner/name) с этим конфигом: источник автообновления и раннера.";
    };

    kiosk.url = lib.mkOption {
      type = lib.types.str;
      default = "https://example.com";
      description = "Страница, которую Chromium открывает в киоск-режиме.";
    };

    runner.enable = lib.mkEnableOption ''
      self-hosted GitHub Actions runner на этой Pi (деплой по push в main).
      Требует секрет github-runner-token (fine-grained PAT) в secrets/secrets.yaml —
      см. README. Даёт раннеру root-эквивалентный доступ через sudo'';
  };
}
