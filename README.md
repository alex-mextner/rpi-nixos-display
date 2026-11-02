# rpi-nixos-display

GitOps-конфигурация Raspberry Pi 4 на NixOS 26.05:

- **киоск**: `cage` (Wayland) + Chromium на весь экран, URL задаётся одной опцией;
- **Wi-Fi** (wpa_supplicant), **SSH** только по ключам, **mDNS** (`rpi4.local`);
- **k3s** + **ArgoCD** (ставится HelmController-ом k3s); приложения живут в `k8s/apps/` и применяются автоматически;
- **автообновление**: раз в сутки Pi сама делает `nixos-rebuild switch` на `main` из этого репозитория, без перезагрузки;
- **секреты** только через [sops-nix](https://github.com/Mic92/sops-nix) + [age](https://age-encryption.org): в репозитории лежит зашифрованный `secrets/secrets.yaml`, в `/nix/store` секреты не попадают;
- необязательный **self-hosted GitHub runner** для мгновенного деплоя по `git push` (по умолчанию выключен).

## Архитектура

```
git push ─► GitHub (main) ─┬─► Pi: system.autoUpgrade (04:00 ± 30 мин) ─► nixos-rebuild switch
                           ├─► Pi: self-hosted runner (опц.) ─► rpi4-deploy (polkit) ─► nixos-upgrade.service
                           └─► ArgoCD в k3s (root-app) ─► k8s/apps/** ─► кластер
```

```
flake.nix, flake.lock         nixpkgs nixos-26.05 (та же ревизия, что в образе на SD) + sops-nix
nixos/
  default.nix                 общие настройки + раздел «Настройки» (URL киоска, runner.enable); подключает все nixos/*.nix автоматически
  options.nix                 опции rpi4.* (repo, kiosk.url, runner.enable)
  hardware.nix                железо RPi4: sd-image-aarch64 (fileSystems по меткам NIXOS_SD/FIRMWARE, U-Boot/extlinux), kernelParams
  secrets.nix                 sops-nix: ключ расшифровки = SSH host-ключ Pi
  wifi.nix                    Wi-Fi «moscow», пароль из секрета wifi-env; wifi-powersave-off
  ssh.nix                     sshd, ключи из keys/*.pub, avahi
  kiosk.nix                   cage + Chromium
  k3s.nix                     k3s, ArgoCD (HelmChart), root-app, firewall
  autoupgrade.nix             system.autoUpgrade
  runner.nix                  GitHub runner (опционально)
keys/admin.pub                публичные SSH-ключи (любые keys/*.pub получают root по SSH)
secrets/secrets.yaml          ЗАШИФРОВАННЫЕ секреты (sops, age)
.sops.yaml                    получатели: ключ админа и ключ Pi (из SSH host-ключа)
k8s/apps/                     приложения под управлением ArgoCD (пример: hello/); корневое приложение root-apps задано в nixos/k3s.nix и берёт репозиторий из rpi4.repo
.github/workflows/deploy.yml  CI: nix flake check, проверка шифрования секретов, gitleaks; деплой через runner
scripts/check-secrets-encrypted.py  проверка: все значения secrets.yaml имеют вид ENC[AES256_GCM,...]
```

## Как работает шифрование секретов

`secrets/secrets.yaml` зашифрован для двух age-получателей (см. `.sops.yaml`):

| получатель | чей приватный ключ | зачем |
|---|---|---|
| `admin` | `~/.config/sops/age/keys.txt` на машине администратора | править секреты (`sops secrets/secrets.yaml`) |
| `rpi4` | `/etc/ssh/ssh_host_ed25519_key` на самой Pi (age-ключ = `ssh-to-age`) | Pi расшифровывает секреты при активации системы в `/run/secrets` (tmpfs) |

Приватные ключи в репозитории не хранятся. Сейчас в секретах:

| ключ | содержимое |
|---|---|
| `wifi-env` | одна строка `WIFI_PSK=<пароль Wi-Fi>` |
| `github-runner-token` | (только если включён раннер) fine-grained PAT |

Формат Wi-Fi секрета проверен по исходникам wpa_supplicant (`ext_password_file`): значение — всё после первого `=` до конца строки, поэтому `#` и другие символы в пароле допустимы; фраза должна быть 8–63 символа (либо 64 hex).

## Первый запуск (bootstrap)

SD-карта уже подготовлена: образ NixOS 26.05 для RPi4, `/etc/wpa_supplicant.conf` (Wi-Fi для первого подключения, **не удалять**), SSH-ключ администратора, SSH host-ключ Pi (из него получен age-ключ `rpi4` в `.sops.yaml`) и клон этого репозитория в `/etc/nixos`.

1. Вставьте SD в Pi, включите; найдите её: `ssh root@rpi4.local` (или IP в роутере).
2. Первое применение (нужен интернет, скачивается замыкание Chromium/k3s из cache.nixos.org; SD расширяется при первом старте автоматически):
   ```sh
   cd /etc/nixos
   nixos-rebuild switch --flake .#rpi4
   ```
3. Проверка: `systemctl status cage-tty1 k3s wpa_supplicant`, на HDMI — Chromium с `rpi4.kiosk.url`; `kubectl get pods -A` (ArgoCD поднимается несколько минут).

Дальше обновления приходят сами (`system.autoUpgrade`) или вручную: `cd /etc/nixos && git pull && nixos-rebuild switch --flake .#rpi4`.

### Если SD перепрошита (host-ключ изменился)

Новый `/etc/ssh/ssh_host_ed25519_key` = новый age-ключ, старые секреты Pi расшифровать не сможет. На машине администратора:

```sh
# у перепрошитой Pi другой host-ключ: сверьте отпечаток (например, по консоли Pi) и обновите known_hosts
ssh-keygen -R rpi4.local
ssh root@rpi4.local cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age   # новый age1...
# заменить age-ключ &rpi4 в .sops.yaml, затем:
sops updatekeys secrets/secrets.yaml
sops rotate --in-place secrets/secrets.yaml   # новый ключ данных (старый host-ключ считается скомпрометированным)
git commit -am "chore(secrets): rotate rpi4 age key" && git push
```

## Повседневные операции

**Сменить страницу киоска** — `rpi4.kiosk.url` в `nixos/default.nix`, `git push` (применится автообновлением или раннером).

**Сменить пароль Wi-Fi / другой секрет**

```sh
sops secrets/secrets.yaml      # откроется редактор с расшифрованным содержимым
git add secrets/secrets.yaml && git commit -m "chore(secrets): update wifi" && git push
```

На новой машине админа нужен age-ключ из `~/.config/sops/age/keys.txt` (`age-keygen -o ...`), его публичную часть надо добавить в `.sops.yaml` (`&admin`) и выполнить `sops updatekeys secrets/secrets.yaml` с уже работающим ключом.

**Добавить SSH-ключ** — положить публичный ключ в `keys/<имя>.pub`, `git push`. Файлы `keys/*.pub` подхватываются автоматически.

**Приложения в k3s** — положить YAML в `k8s/apps/<имя>/`, `git push`; ArgoCD (root-app) применит его сам (`prune` и `selfHeal` включены). Секреты Kubernetes в открытом виде в `k8s/` класть нельзя: нужен sops-совместимый механизм (например ksops/sops-secrets-operator), он здесь ещё не настроен. Доступ к ArgoCD UI: `kubectl -n argocd port-forward svc/argocd-server 8080:443`, пароль — `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.

Защита ArgoCD: он не удаляет всё из кластера, если `k8s/apps/` стал пустым (`allowEmpty` выключен намеренно). Чтобы убрать последнее приложение, удалите его ресурсы вручную (`kubectl delete`) или оставьте в `k8s/apps/` хотя бы один ресурс.

**kubectl с другой машины** — `scp root@rpi4.local:/etc/rancher/k3s/k3s.yaml ./k3s.yaml`, заменить `127.0.0.1` на `rpi4.local` и указать файл: `export KUBECONFIG="$PWD/k3s.yaml"` (или `kubectl --kubeconfig ./k3s.yaml ...`). Сертификат API содержит `rpi4.local` (`--tls-san`). Порт 6443 открыт в файрволе; kubeconfig на Pi имеет права 0600 (в старом черновике было 0644 — убрано: не нужно, на Pi kubectl запускается под root).

## Self-hosted GitHub runner (опционально)

Раннер выключен (`rpi4.runner.enable = false`). Включать только осознанно — см. риски ниже.

1. **PAT.** Регистрационные токены раннера живут 1 час, поэтому `tokenFile` должен содержать PAT. Создайте fine-grained PAT (GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens):
   - Resource owner: ваш аккаунт; **Repository access: Only select repositories → `rpi-nixos-display`**;
   - Repository permissions: **Administration: Read and write** (нужно для получения токена регистрации repo-раннера; больше ничего не давать);
   - срок жизни — минимально разумный (раз в N месяцев перевыпускать).
2. **Секрет.** `sops secrets/secrets.yaml` и добавить строку `github-runner-token: github_pat_...`.
3. **Включить.** В `nixos/default.nix` поставить `runner.enable = true`, закоммитить, запушить, применить (`nixos-rebuild switch --flake .#rpi4` на Pi или автообновление).
4. **Разрешить деплой-задачу.** В репозитории: Settings → Secrets and variables → Actions → Variables → `RPI_RUNNER_ENABLED = true`. Пока переменной нет, job `deploy` пропускается и не висит в очереди.
5. Проверка: Settings → Actions → Runners — раннер `rpi4-nixos` в статусе Idle.

`deploy.yml` запускается только на `push` в `main` и вручную. Деплой: `rpi4-deploy` → `systemctl start nixos-upgrade.service` (разрешено пользователю раннера правилом polkit, без sudo) → `nixos-rebuild switch --refresh --flake github:alex-mextner/rpi-nixos-display#rpi4`. Если в этот момент уже идёт плановое обновление, `rpi4-deploy` дожидается его и запускает обновление заново, чтобы применилась свежая ревизия.

Сам юнит раннера при `switch` не перезапускается (иначе деплой прервал бы собственную задачу): изменения в `nixos/runner.nix` вступают в силу после `systemctl restart github-runner-rpi4` или ребута.

## Риски и ограничения

- **Раннер в публичном репозитории.** Код workflow исполняется на Pi. Тот, кто может пушить в `main` (или изменить workflow), управляет конфигурацией Pi, а значит де-факто имеет **root-эквивалентный доступ** к ней: любая конфигурация, попавшая в `main`, применяется от root. Меры, которые уже приняты: триггеры только `push: main` и `workflow_dispatch` (никаких `pull_request*`), для внешних контрибьюторов включено ручное одобрение запуска workflow (`fork-pr-contributor-approval = all_external_contributors`), раннер сам права root не имеет (песочница systemd-юнита раннера не ослаблена), сторонние actions закреплены по SHA. Рекомендуется включить защиту ветки `main` (обязательное review) и не давать write-доступ посторонним.
- **Отклонение от первоначального плана: polkit вместо sudo.** Исходный план предполагал `sudo NOPASSWD nixos-rebuild`. Setuid-`sudo` внутри юнита раннера не работает: seccomp-фильтры песочницы systemd неявно включают `NoNewPrivileges`, и пришлось бы отключать песочницу целиком (а `sudo nixos-rebuild` дал бы root с произвольными аргументами). Вместо этого правило polkit разрешает пользователю `github-runner` единственное действие: `systemctl start nixos-upgrade.service` (root-юнит автообновления; свой flake раннер подставить не может). Работа polkit-правила с песочницей юнита на железе не проверена.
- **PAT виден в аргументах процесса при регистрации раннера.** Модуль раннера nixpkgs запускает `Runner.Listener configure --pat <PAT>`; в момент регистрации (старт юнита, смена PAT) любой локальный пользователь Pi (например `kiosk`) может прочитать токен из `/proc/*/cmdline`. Это ограничение апстрима: используйте PAT с минимальными правами (см. выше) и коротким сроком жизни, а при подозрении на компрометацию браузера киоска отзовите его. Файл секрета на диске доступен только root.
- **Автообновление доверяет `main`.** Любой коммит в `main` через сутки окажется на Pi (с правами root). Секреты в чужом коммите не утекут (они зашифрованы), но подмена конфигурации = полный контроль.
- **Публичный `secrets.yaml`.** Он зашифрован, но лежит в публичной истории навсегда: тот, у кого есть приватный ключ админа или host-ключ Pi, расшифрует и все прошлые версии секретов. `sops updatekeys` меняет только получателей, но не ключ данных, поэтому после компрометации: убрать скомпрометированный ключ из `.sops.yaml`, выполнить `sops updatekeys secrets/secrets.yaml`, затем `sops rotate --in-place secrets/secrets.yaml` (новый ключ данных) и обязательно **сменить сами секреты** (пароль Wi-Fi, PAT) — старые значения остаются доступными в истории git.
- **Host-ключ Pi** — единственная копия приватной части на SD (в репозиторий и в бэкапы не попадает). Потеря SD = перегенерация ключей и `sops updatekeys` (см. выше).
- **Слабый Wi-Fi пароль.** Минимальная длина WPA-фразы — 8 символов.
- **Первый `nixos-rebuild` на Pi** вычисляет flake на самой Pi: на 2 ГБ ОЗУ возможна нехватка памяти — используйте swap или модель с 4+ ГБ.
- **Не проверено на железе.** Конфигурация проверена вычислением (`nix flake check --no-build`, eval aarch64 на x86_64), но не сборкой и не запуском. Особенно: поведение Chromium под cage на Pi 4, HelmController k3s без интернета, порядок применения манифестов ArgoCD (k3s повторяет `apply`, пока не появятся CRD).
- **Порт 6443** открыт для всей локальной сети (аутентификация клиентскими сертификатами k3s). Закройте в `nixos/k3s.nix`, если удалённый `kubectl` не нужен.
- Пользователь `nixos` из исходного образа этой конфигурацией не создаётся; вход — только `root` по ключу из `keys/`.

## Проверка конфигурации локально

```sh
nix flake check --no-build
nix eval .#nixosConfigurations.rpi4.config.system.build.toplevel.drvPath
```

Новые файлы должны быть добавлены в git (`git add`), иначе flake их не видит.
