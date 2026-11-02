# Self-hosted GitHub Actions runner (по умолчанию ВЫКЛЮЧЕН: rpi4.runner.enable).
#
# ВАЖНО: репозиторий публичный. Раннер исполняет код workflow на этой Pi, поэтому
#   * .github/workflows/deploy.yml запускается только на push в main и вручную —
#     никаких pull_request / pull_request_target;
#   * в настройках репозитория внешние контрибьюторы требуют одобрения запуска;
#   * тот, кто может пушить в main, управляет конфигурацией Pi, то есть де-факто
#     имеет root на ней (README, раздел «Риски»).
#
# Как раннер запускает деплой: не через sudo, а через polkit. Setuid-sudo несовместим
# с песочницей юнита раннера (seccomp-фильтры systemd включают NoNewPrivileges), а
# отключать песочницу целиком хуже. Вместо этого пользователю раннера разрешено
# ровно одно действие: запустить nixos-upgrade.service (root-юнит автообновления,
# см. autoupgrade.nix). Раннер не может подставить свой flake или аргументы.
{ config, lib, pkgs, ... }:
let
  cfg = config.rpi4.runner;
  runnerName = "rpi4";
  runnerUser = "github-runner";

  # Если плановое обновление уже идёт (oneshot-юнит в состоянии activating), systemd
  # присоединяет второй start к нему и применится старая ревизия: дожидаемся его
  # конца и запускаем обновление заново.
  deploy = pkgs.writeShellScriptBin "rpi4-deploy" ''
    systemctl=/run/current-system/sw/bin/systemctl
    state=$($systemctl show --property=ActiveState --value nixos-upgrade.service)
    if [ "$state" = activating ] || [ "$state" = active ]; then
      $systemctl start nixos-upgrade.service || true
    fi
    exec $systemctl start nixos-upgrade.service
  '';
in
{
  config = lib.mkIf cfg.enable {
    # Токен регистрации раннера живёт 1 час, поэтому здесь нужен fine-grained PAT
    # (Administration: Read and write на этот репозиторий) — см. README.
    # Файл остаётся root:root 0400: читает его только привилегированный шаг регистрации
    # модуля раннера, код workflow (пользователь раннера) токен прочитать не должен.
    sops.secrets.github-runner-token = { };

    users.groups.${runnerUser} = { };
    users.users.${runnerUser} = {
      isSystemUser = true;
      group = runnerUser;
    };

    services.github-runners.${runnerName} = {
      enable = true;
      url = "https://github.com/${config.rpi4.repo}";
      name = "rpi4-nixos";
      tokenFile = config.sops.secrets.github-runner-token.path;
      user = runnerUser;
      # После смены PAT модуль перерегистрирует раннер под тем же именем.
      replace = true;
      extraLabels = [
        "rpi4"
        "nixos"
      ];
      extraPackages = [ pkgs.git ];
    };

    # Не перезапускать раннер во время switch: иначе деплой прервёт собственную задачу
    # (изменения юнита раннера вступят в силу после его ручного рестарта или ребута).
    systemd.services."github-runner-${runnerName}".restartIfChanged = false;

    environment.systemPackages = [ deploy ];

    security.polkit = {
      enable = true;
      extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "nixos-upgrade.service" &&
              action.lookup("verb") == "start" &&
              subject.user == "${runnerUser}") {
            return polkit.Result.YES;
          }
        });
      '';
    };
  };
}
