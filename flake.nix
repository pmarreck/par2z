{
	description = "par2z dev shell";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		zig-overlay = {
			url = "github:mitchellh/zig-overlay";
			inputs.nixpkgs.follows = "nixpkgs";
		};
	};

	outputs = { self, nixpkgs, zig-overlay }:
		let
			systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
			forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
			zigFor = system: zig-overlay.packages.${system}."0.16.0";
		in {
			packages = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					zig = zigFor system;
				in {
					default = pkgs.stdenvNoCC.mkDerivation {
						name = "par2z";
						src = self;
						nativeBuildInputs = [ zig ];
						dontConfigure = true;
						dontFixup = true;
						buildPhase = ''
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							zig build -Doptimize=ReleaseFast --prefix $out
						'';
						# zig build --prefix handles install
						dontInstall = true;
					};
				});

			checks = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					zig = zigFor system;
				in {
					test = pkgs.stdenv.mkDerivation {
						name = "par2z-test";
						src = self;
						nativeBuildInputs = [ zig pkgs.par2cmdline ]
							++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];
						dontConfigure = true;
						dontFixup = true;
						buildPhase = ''
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							# Compile tests without running. On Linux, Zig links libc
							# with the FHS dynamic-linker path which doesn't exist in
							# the Nix sandbox; patchelf can't always rewrite Zig 0.16's
							# ELFs (page-size assertion fails), so we invoke Nix's
							# dynamic linker directly with the binary as its argument.
							zig build test-compile --prefix $TMPDIR/out
							${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
							DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
							"$DL" $TMPDIR/out/par2z/bin/test
							''}
							${pkgs.lib.optionalString (!pkgs.stdenv.isLinux) ''
							$TMPDIR/out/par2z/bin/test
							''}
						'';
						installPhase = "touch $out";
					};
				});

			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					zig = zigFor system;
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
							zig
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
						'';
					};
				});
		};
}
