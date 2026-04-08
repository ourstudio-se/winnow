{
  description = "Opinionated observability UI built on Quickwit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = {
    self,
    nixpkgs,
    zig2nix,
  }: let
    flake-utils = zig2nix.inputs.flake-utils;
  in
    flake-utils.lib.eachDefaultSystem (
      system: let
        env = zig2nix.outputs.zig-env.${system} {};
        pkgs = env.pkgs;
        pnpmDeps = pkgs.fetchPnpmDeps {
          pname = "winnow-frontend";
          src = ./frontend;
          hash = "sha256-tKSerRVTBY4pSjaK0SuwGx/OFTMRg2gHA7ELKk6bWqo=";
          fetcherVersion = 3;
        };
      in {
        packages.frontend = pkgs.stdenvNoCC.mkDerivation {
          pname = "winnow-frontend";
          version = "0.0.0";
          src = ./frontend;
          nativeBuildInputs = [
            pkgs.nodejs_22
            pkgs.pnpm
            pkgs.pnpmConfigHook
          ];
          inherit pnpmDeps;
          buildPhase = ''
            pnpm build
          '';
          installPhase = ''
            cp -r dist $out
          '';
        };

        packages.default = env.package {
          pname = "winnow";
          version = "0.0.0";
          src = ./backend;

          # protoc is needed for the gen-proto build step
          nativeBuildInputs = [pkgs.protobuf];

          # Generate protobuf Zig code and embed frontend assets before the main build.
          # This creates static_assets.zig so zig build's auto-detect skips frontend steps.
          preBuild = ''
            # Link frontend dist for @embedFile resolution
            ln -s ${self.packages.${system}.frontend} src/server/frontend-dist

            # Generate static asset embedding module
            bash ${./scripts/embed-frontend.sh} src/server/frontend-dist src/server/static_assets.zig

            # Generate protobuf code
            zig build gen-proto --system "$ZIG_GLOBAL_CACHE_DIR/p"
          '';

          doCheck = true;
          checkPhase = ''
            zig build test --system "$ZIG_GLOBAL_CACHE_DIR/p"
          '';

          meta.mainProgram = "winnow";
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
            echo "winnow dev shell"
            echo "  zig:  $(zig version)"
            echo "  node: $(node --version)"
            echo "  pnpm: $(pnpm --version)"
          '';
        };

        checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          integration = pkgs.callPackage ./tests/integration.nix {
            winnow = self.packages.${system}.default;
          };
        };

        packages.generate-data = pkgs.writers.writePython3Bin "generate-data" {
          libraries = [
            pkgs.python3Packages.opentelemetry-api
            pkgs.python3Packages.opentelemetry-sdk
            pkgs.python3Packages.opentelemetry-exporter-otlp-proto-http
          ];
          doCheck = false;
        } (builtins.readFile ./scripts/generate-data.py);

        packages.nuke-indices = pkgs.writeShellScriptBin "nuke-indices" ''
          exec ${pkgs.python3}/bin/python3 ${./scripts/nuke-indices.py} "$@"
        '';

        # TODO: packages.docker-image = OCI image
      }
    );
}
