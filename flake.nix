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
        embed-frontend = pkgs.writeShellScript "embed-frontend" ''
          set -euo pipefail
          DIST_DIR="$1"
          OUTPUT="$2"
          if [ ! -d "$DIST_DIR" ]; then
            echo "error: dist directory '$DIST_DIR' does not exist" >&2
            exit 1
          fi
          OUTPUT_DIR="$(dirname "$OUTPUT")"
          REL_DIST="$(${pkgs.coreutils}/bin/realpath -s --relative-to="$OUTPUT_DIR" "$DIST_DIR")"

          mime_type() {
            case "$1" in
              *.html) echo "text/html" ;;
              *.js)   echo "application/javascript" ;;
              *.css)  echo "text/css" ;;
              *.svg)  echo "image/svg+xml" ;;
              *.woff2) echo "font/woff2" ;;
              *.woff) echo "font/woff" ;;
              *.ttf)  echo "font/ttf" ;;
              *.png)  echo "image/png" ;;
              *.ico)  echo "image/x-icon" ;;
              *.json) echo "application/json" ;;
              *.txt)  echo "text/plain" ;;
              *.webmanifest) echo "application/manifest+json" ;;
              *)      echo "application/octet-stream" ;;
            esac
          }

          sanitize_ident() {
            echo "$1" | ${pkgs.gnused}/bin/sed 's/[^a-zA-Z0-9]/_/g' | ${pkgs.gnused}/bin/sed 's/^_//' | ${pkgs.gnused}/bin/sed 's/__*/_/g'
          }

          {
            echo "const std = @import(\"std\");"
            echo ""
            echo "pub const Asset = struct {"
            echo "    content: []const u8,"
            echo "    content_type: []const u8,"
            echo "    cacheable: bool,"
            echo "};"
            echo ""

            declare -a files=()
            declare -a idents=()
            declare -a mimes=()
            declare -a cacheables=()

            while IFS= read -r -d "" file; do
              rel="''${file#"$DIST_DIR"/}"
              files+=("$rel")
              ident="$(sanitize_ident "$rel")"
              idents+=("$ident")
              mimes+=("$(mime_type "$rel")")
              if [[ "$rel" == assets/* ]]; then
                cacheables+=("true")
              else
                cacheables+=("false")
              fi
            done < <(${pkgs.findutils}/bin/find -L "$DIST_DIR" -type f -print0 | ${pkgs.coreutils}/bin/sort -z)

            for i in "''${!files[@]}"; do
              echo "const ''${idents[$i]} = @embedFile(\"''${REL_DIST}/''${files[$i]}\");"
            done

            echo ""
            echo "const Entry = struct { path: []const u8, asset: Asset };"
            echo ""
            echo "const assets = [_]Entry{"

            for i in "''${!files[@]}"; do
              if [ "''${files[$i]}" = "index.html" ]; then
                echo "    .{ .path = \"/\", .asset = .{ .content = ''${idents[$i]}, .content_type = \"''${mimes[$i]}\", .cacheable = false } },"
                break
              fi
            done

            for i in "''${!files[@]}"; do
              echo "    .{ .path = \"/''${files[$i]}\", .asset = .{ .content = ''${idents[$i]}, .content_type = \"''${mimes[$i]}\", .cacheable = ''${cacheables[$i]} } },"
            done

            echo "};"
            echo ""
            echo "pub fn lookup(path: []const u8) ?Asset {"
            echo "    for (&assets) |*entry| {"
            echo "        if (std.mem.eql(u8, entry.path, path)) return entry.asset;"
            echo "    }"
            echo "    return null;"
            echo "}"
          } > "$OUTPUT"

          echo "Generated $OUTPUT with ''${#files[@]} embedded assets"
        '';
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
          pnpmDeps = pkgs.fetchPnpmDeps {
            pname = "winnow-frontend";
            src = ./frontend;
            hash = "sha256-tKSerRVTBY4pSjaK0SuwGx/OFTMRg2gHA7ELKk6bWqo=";
            fetcherVersion = 3;
          };
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

          # Generate protobuf Zig code and embed frontend assets before the main build
          preBuild = ''
            # Link frontend dist for @embedFile resolution
            ln -s ${self.packages.${system}.frontend} src/frontend-dist

            # Generate static asset embedding module
            bash ${embed-frontend} src/server/frontend-dist src/server/static_assets.zig

            # Generate protobuf code
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
