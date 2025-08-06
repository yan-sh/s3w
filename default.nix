{kind ? "develop", version ? "latest"} :

let

  bootstrap = import <nixpkgs> { };
  unstable = import <nixpkgs-unstable> { };

  nixpkgs = builtins.fromJSON (builtins.readFile ./nixpkgs.json);

  src = bootstrap.fetchFromGitHub {
    owner = "NixOS";
    repo  = "nixpkgs"; inherit (nixpkgs) rev sha256;
  };

  pkgs = import src { inherit config;};

  ghcVersion = "ghc94";

  config = {
    packageOverrides = pkgs: rec {
      haskell = pkgs.haskell // {
        packages = pkgs.haskell.packages // {
          "${ghcVersion}" = pkgs.haskell.packages."${ghcVersion}".override {
            overrides = haskellPackagesNew: haskellPackagesOld: rec {
              co-log-json = haskellPackagesNew.callPackage ./co-log-json.nix { };
              minio-hs = haskellPackagesNew.callPackage ./minio-hs-github.nix { };
              s3w = haskellPackagesNew.developPackage {
                root = ./.;
                modifier = (t.flip t.pipe)
                  [
                    (t.flip pkgs.haskell.lib.setBuildTarget "s3w")
                    pkgs.haskell.lib.disableLibraryProfiling   
                    pkgs.haskell.lib.disableExecutableProfiling
                    pkgs.haskell.lib.dontCheck
                    pkgs.haskell.lib.dontHaddock
                    pkgs.haskell.lib.dontBenchmark
                    pkgs.haskell.lib.dontCoverage
                    pkgs.haskell.lib.doStrip
                    pkgs.haskell.lib.justStaticExecutables
                    withoutDistNewstyle
                  ];
              };
            };
          };
        };
      };
    };
  };

  withoutDistNewstyle = drv: pkgs.haskell.lib.overrideCabal drv
    ( x:  { src = builtins.filterSource
            ( name: type:
                let base = builtins.baseNameOf name;
                in pkgs.lib.cleanSourceFilter name type
                    && (type != "directory" ||  (base != "dist" && base != "dist-newstyle"))
            ) x.src;       
          }
      );

  t = pkgs.lib.trivial;

  in
    pkgs.haskell.packages."${ghcVersion}".s3w
