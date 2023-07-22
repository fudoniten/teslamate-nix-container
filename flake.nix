{
  description = "TeslaMate running in a container";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.05";
    arion.url = "github:hercules-ci/arion";
  };

  outputs = { self, nixpkgs, arion, ... }: {
    nixosModules = rec {
      default = teslaMateContainer;
      teslaMateContainer = { ... }: {
        imports = [ arion.nixosModules.arion ./tesla-mate-container.nix ];
      };
    };
  };
}
