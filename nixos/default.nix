# Корневой модуль конфигурации rpi4: подключает тематические модули и задаёт настройки.
# Каждый nixos/*.nix (кроме этого файла) подключается автоматически:
# новый модуль = новый файл, список импортов вести не нужно.
{ lib, pkgs, ... }:
{
  imports = lib.pipe (builtins.readDir ./.) [
    (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix"))
    builtins.attrNames
    (map (name: ./. + "/${name}"))
  ];

  # ── Настройки ──────────────────────────────────────────────────────────────
  rpi4 = {
    kiosk.url = "https://example.com"; # <- поменяйте на свою страницу
    runner.enable = false; # <- true только после добавления github-runner-token, см. README
  };

  # ── Система ────────────────────────────────────────────────────────────────
  # Образ на SD собран из nixos-26.05; stateVersion не менять после первой установки.
  system.stateVersion = "26.05";
  networking.hostName = "rpi4";

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;
  };

  # Старые поколения не должны забить SD-карту.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  environment.systemPackages = with pkgs; [
    git # нужен nix для flake в git-репозитории (/etc/nixos)
    vim
    htop
    iw
    kubectl
    kubernetes-helm
    sops
    age
    ssh-to-age
  ];
}
