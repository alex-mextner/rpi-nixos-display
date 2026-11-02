# k3s (одиночный сервер) + ArgoCD через HelmController k3s.
# k3s сам применяет манифесты из /var/lib/rancher/k3s/server/manifests;
# services.k3s.manifests кладёт туда файлы из /nix/store.
# Дальше все приложения живут в k8s/apps/ этого репозитория: корневое приложение
# ArgoCD (root-apps, ниже) синхронизирует их автоматически (GitOps).
{ config, ... }:
{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = toString [
      "--disable=servicelb"
      # Имя из mDNS попадает в сертификат API: kubectl с другой машины ходит на rpi4.local.
      "--tls-san=rpi4.local"
      # kubeconfig остаётся 0600 root (/etc/rancher/k3s/k3s.yaml): kubectl на Pi — под root.
      # Снаружи: scp root@rpi4.local:/etc/rancher/k3s/k3s.yaml и сменить server на rpi4.local.
    ];

    manifests = {
      argocd-namespace.content = {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = "argocd";
      };

      argocd.content = {
        apiVersion = "helm.cattle.io/v1";
        kind = "HelmChart";
        metadata = {
          name = "argocd";
          namespace = "kube-system";
        };
        spec = {
          repo = "https://argoproj.github.io/argo-helm";
          chart = "argo-cd";
          version = "10.11.6"; # закреплена; обновлять осознанно
          targetNamespace = "argocd";
          # Pi 4: убираем лишние компоненты, которые для этого сценария не нужны.
          valuesContent = ''
            dex:
              enabled: false
            notifications:
              enabled: false
          '';
        };
      };

      # Корневое приложение (app-of-apps): следит за k8s/apps/ репозитория rpi4.repo.
      # CRD появляются после установки чарта; k3s повторяет apply, пока не получится.
      argocd-root-app.content = {
        apiVersion = "argoproj.io/v1alpha1";
        kind = "Application";
        metadata = {
          name = "root-apps";
          namespace = "argocd";
        };
        spec = {
          project = "default";
          source = {
            repoURL = "https://github.com/${config.rpi4.repo}.git";
            targetRevision = "HEAD";
            path = "k8s/apps";
            directory.recurse = true;
          };
          destination = {
            server = "https://kubernetes.default.svc";
            namespace = "default";
          };
          syncPolicy.automated = {
            prune = true; # удалить из кластера то, что удалено из git
            selfHeal = true; # вернуть ручные правки к состоянию из git
          };
        };
      };
    };
  };

  # SSH (22) открывает сам openssh; 6443 — API k3s (доступ по клиентскому сертификату).
  networking.firewall.allowedTCPPorts = [ 6443 ];
}
