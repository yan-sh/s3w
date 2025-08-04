{version, gitrev ? "", registry} :

let
  bootstrap = import <nixpkgs> { };
  unstable = import <nixpkgs-unstable> { };
 
  nixpkgs = builtins.fromJSON (builtins.readFile ./nixpkgs.json);
  
  src = bootstrap.fetchFromGitHub {
    owner = "NixOS";
    repo  = "nixpkgs";
    inherit (nixpkgs) rev sha256;
  };

  pkgs = import src {};

  s3w = pkgs.haskellPackages.callPackage ./default.nix {};

in

  bootstrap.dockerTools.buildImage {
    name = "${registry}/s3w";
    tag = "${version + (if gitrev == "" then "" else ("." + gitrev))}";
    copyToRoot = pkgs.buildEnv {
      name = "image-root";
      paths = [ pkgs.coreutils pkgs.bash pkgs.ps pkgs.killall ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [ "${s3w}/bin/s3w" ];
    created = "now"; 
  }
