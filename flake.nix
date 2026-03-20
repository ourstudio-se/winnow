{
  description = "Opinionated observability UI built on Quickwit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = { self, nixpkgs, zig2nix }:
    let
      flake-utils = zig2nix.inputs.flake-utils;
    in flake-utils.lib.eachDefaultSystem (system:
      let
        env = zig2nix.outputs.zig-env.${system} {};
        pkgs = env.pkgs;
      in {
        packages.default = env.package {
          pname = "telemetry-experiment";
          version = "0.0.0";
          src = ./backend;

          # protoc is needed for the gen-proto build step
          nativeBuildInputs = [ pkgs.protobuf ];

          # Generate protobuf Zig code before the main build
          preBuild = ''
            zig build gen-proto --system "$ZIG_GLOBAL_CACHE_DIR/p"
          '';

          doCheck = true;
          checkPhase = ''
            zig build test --system "$ZIG_GLOBAL_CACHE_DIR/p"
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Backend
            zig
            zls

            # Frontend
            nodejs_22
            nodePackages.pnpm

            # Tools
            protobuf
            grpcurl
            curl
            jq

            # Data generation
            self.packages.${system}.generate-data
            self.packages.${system}.nuke-indices
          ];

          shellHook = ''
            export QUICKWIT_URL=http://localhost:7290
            echo "telemetry-experiment dev shell"
            echo "  zig:  $(zig version)"
            echo "  node: $(node --version)"
            echo "  pnpm: $(pnpm --version)"
          '';
        };

        checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          integration = pkgs.callPackage ./tests/integration.nix {
            telemetry-experiment = self.packages.${system}.default;
          };
        };

        packages.generate-data = let
          py = pkgs.python3.withPackages (ps: with ps; [
            opentelemetry-api
            opentelemetry-sdk
            opentelemetry-exporter-otlp-proto-http
          ]);
        in pkgs.writeShellScriptBin "generate-data" ''
          exec ${py}/bin/python3 ${./scripts/generate-data.py} "$@"
        '';

        packages.nuke-indices = pkgs.writeShellScriptBin "nuke-indices" ''
          exec ${pkgs.python3}/bin/python3 ${./scripts/nuke-indices.py} "$@"
        '';

        # TODO: packages.docker-image = OCI image
      }
    );
}
