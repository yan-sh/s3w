{pkgs ? import <nixpkgs> { }}:
let
  unstable = import <nixpkgs-unstable> {};

  nixpkgs = builtins.fromJSON (builtins.readFile ./nixpkgs.json);
 
  src = pkgs.fetchFromGitHub {
    owner = "NixOS";
    repo  = "nixpkgs";
    inherit (nixpkgs) rev sha256;
  };

  pkgs_ = import src {};

in
  pkgs_.mkShell {
    packages =
      [ 
        pkgs_.cabal-install
        pkgs_.haskell.packages.ghc94.ghc-tags
        pkgs_.zlib
        unstable.ghcid
        pkgs_.cabal2nix
      ];
    inputsFrom = [(import ./default.nix {})];
  }
