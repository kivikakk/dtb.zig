{
  description = "dtb.zig development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";

    zls-flake.url = "github:zigtools/zls/0.15.0";
    zls-flake.inputs.nixpkgs.follows = "nixpkgs";
    zls-flake.inputs.zig-overlay.follows = "zig-overlay";
  };

  outputs =
    {
      self,
      nixpkgs,
      zig-overlay,
      zls-flake,
    }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      formatter = eachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      devShells = eachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zig = zig-overlay.packages.${system}."0.15.1";
          zls = zls-flake.packages.${system}.zls;
        in
        {
          default = pkgs.mkShell {
            name = "dtb.zig";
            nativeBuildInputs = [
              zig
              zls
            ];
          };
        }
      );
    };
}
