# SSH по ключам + mDNS (rpi4.local).
{ lib, ... }:
{
  services.openssh = {
    enable = true;
    # Ключи только из репозитория (/etc/ssh/authorized_keys.d): старый ключ,
    # удалённый из keys/, не должен продолжать работать через ~/.ssh/authorized_keys.
    authorizedKeysInHomedir = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  # Все публичные ключи из keys/*.pub получают доступ как root.
  # Добавить ключ = положить файл keys/<имя>.pub и сделать git push.
  users.users.root.openssh.authorizedKeys.keyFiles = lib.pipe (builtins.readDir ../keys) [
    builtins.attrNames
    (lib.filter (lib.hasSuffix ".pub"))
    (map (name: ../keys + "/${name}"))
  ];

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };
}
