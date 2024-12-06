{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  outputs = inputs @ { self, nixpkgs }: {
    nixosModules = rec {
      virtual-machine = import ./default.nix;
      default = virtual-machine;
    };
  };
}
