{
  description = "dtb.zig development shell";

  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
    flake-utils.url = github:numtide/flake-utils;

    zig-overlay.url = github:mitchellh/zig-overlay;
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zig-overlay.inputs.flake-utils.follows = "flake-utils";

    zls-flake.url = github:zigtools/zls/0.13.0;
    zls-flake.inputs.nixpkgs.follows = "nixpkgs";
    zls-flake.inputs.flake-utils.follows = "flake-utils";
    zls-flake.inputs.zig-overlay.follows = "zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    zig-overlay,
    zls-flake,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
      zig = zig-overlay.packages.${system}."0.13.0";
      zls = zls-flake.packages.${system}.zls;
    in rec {
      formatter = pkgs.alejandra;

      devShells.default = pkgs.mkShell {
        name = "dtb.zig";
        nativeBuildInputs = [
          zig
          zls
        ];
      };
    });
}
