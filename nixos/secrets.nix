# sops-nix: секреты лежат в репозитории зашифрованными (age), расшифровываются
# при активации системы ключом хоста в tmpfs /run/secrets, в /nix/store не попадают.
{ ... }:
{
  sops = {
    defaultSopsFile = ../secrets/secrets.yaml;
    # SSH host-ключ Pi → age-ключ. Публичная часть (ssh-to-age) — получатель rpi4 в .sops.yaml.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    # Отдельный age-ключ на устройстве не создаём.
    age.generateKey = false;
  };
}
