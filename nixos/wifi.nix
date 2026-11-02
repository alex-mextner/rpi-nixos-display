# Wi-Fi: SSID в конфиге, пароль — только в sops-секрете wifi-env.
{ config, pkgs, ... }:
{
  # Содержимое секрета wifi-env (в расшифрованном виде):  WIFI_PSK=<пароль>
  # wpa_supplicant ext_password_backend=file читает строки NAME=значение; значение —
  # всё после первого «=» до конца строки (символ «#» допустим, комментарий — только
  # строка, НАЧИНАЮЩАЯСЯ с «#»), длина фразы 8..63 (либо 64 hex).
  sops.secrets.wifi-env = {
    # wpa_supplicant работает под этим пользователем (enableHardening)
    owner = "wpa_supplicant";
    # wpa_supplicant держит файл секрета смонтированным: после смены пароля нужен рестарт
    restartUnits = [ "wpa_supplicant.service" ];
  };

  networking.wireless = {
    enable = true;
    secretsFile = config.sops.secrets.wifi-env.path;
    networks."moscow".pskRaw = "ext:WIFI_PSK";
  };

  # Wi-Fi чип Broadcom на Pi 4 засыпает при простое — держим бодрым.
  # Юнит привязан к устройству: стартует, когда wlan0 появляется (в том числе после
  # перезагрузки драйвера), и останавливается вместе с ним.
  systemd.services.wifi-powersave-off = {
    description = "Disable Wi-Fi power saving on wlan0";
    bindsTo = [ "sys-subsystem-net-devices-wlan0.device" ];
    wantedBy = [ "sys-subsystem-net-devices-wlan0.device" ];
    after = [
      "sys-subsystem-net-devices-wlan0.device"
      "wpa_supplicant.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.iw}/bin/iw dev wlan0 set power_save off";
    };
  };
}
