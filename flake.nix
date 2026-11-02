{
  description = "Raspberry Pi 4: NixOS-киоск (Chromium/cage) + k3s + ArgoCD, GitOps";

  inputs = {
    # Ветка совпадает с образом на SD (nixos-26.05, ядро 6.18).
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, sops-nix, ... }:
    {
      nixosConfigurations.rpi4 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          sops-nix.nixosModules.sops
          ./nixos
        ];
      };
    };
}
