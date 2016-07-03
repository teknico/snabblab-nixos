with (import <nixpkgs> {});

let
  evalMachine = name:
    let
      modules = [
        (import ../machines/eiger.nix).${name}
        (import ../machines/eiger-production.nix).${name}
        { networking.hostName = name; }
      ];
    in {
      eval = import <nixpkgs/nixos/lib/eval-config.nix> { inherit modules; };
      config = {
        imports = modules;
      };
    };
  machines = ["build1" "build2" "build3" "build4"];
in stdenv.lib.genAttrs machines evalMachine