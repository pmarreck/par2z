{
	description = "par2z dev shell";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
			forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
		in {
			packages = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
				in {
					default = pkgs.stdenv.noCC.mkDerivation {
						name = "par2z";
						src = self;
						nativeBuildInputs = [ pkgs.zig ];
						buildPhase = ''
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							zig build -Doptimize=ReleaseFast
						'';
						installPhase = ''
							mkdir -p $out
							cp -r zig-out/* $out/
						'';
					};
				});

			checks = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
				in {
					fmt = pkgs.stdenv.noCC.mkDerivation {
						name = "par2z-fmt";
						src = self;
						nativeBuildInputs = [ pkgs.zig ];
						buildPhase = ''
							zig fmt --check src/ tests/ fuzz/
						'';
						installPhase = "touch $out";
					};

					test = pkgs.stdenv.noCC.mkDerivation {
						name = "par2z-test";
						src = self;
						nativeBuildInputs = [ pkgs.zig ];
						buildPhase = ''
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							# Use test-direct to avoid any hang issues with the Zig test runner
							zig build test-direct
						'';
						installPhase = "touch $out";
					};
				});

			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					isDarwin = pkgs.stdenv.isDarwin;
					valgrindPkg = if isDarwin then null else pkgs.valgrind;
					linuxOnly = pkgs.lib.optionals (!isDarwin) [
						pkgs.aflplusplus
						pkgs.lcov
					];
					mktmpPkg = pkgs.writeShellScriptBin "mktmp" ''
						#!/usr/bin/env bash
						set -euo pipefail
						if [ "''${1-}" = "--help" ] || [ "''${1-}" = "-h" ]; then
							echo "usage: mktmp [--tmpdir]"
							exit 0
						fi
						if [ "''${1-}" = "--tmpdir" ]; then
							shift
						fi
						dir="''${TMPDIR:-/tmp}"
						mktemp -d "$dir/mktmp.XXXXXX"
					'';
					par2TurboPkg = pkgs.writeShellScriptBin "par2-turbo" ''
						exec ${pkgs.par2cmdline-turbo}/bin/par2 "$@"
					'';
				in {
					default = pkgs.mkShell {
						packages = [
							pkgs.zig
							pkgs.zls
							pkgs.lldb
							pkgs.cmake
							pkgs.ninja
							pkgs.pkg-config
						pkgs.openssl
						pkgs.par2cmdline
						pkgs.luajit
						par2TurboPkg
						mktmpPkg
					] ++ linuxOnly ++ pkgs.lib.optional (valgrindPkg != null) valgrindPkg;

						shellHook = ''
							echo "par2z dev shell: zig/zls/afl++/par2cmdline"
							echo "Linting: use 'zig fmt --check src/' and 'zls' diagnostics"
						'';
					};
				});
		};
}
