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
							# Compile tests + CLI without running. On Linux, Zig links
							# libc with the FHS dynamic-linker path which doesn't exist
							# in the Nix sandbox; patchelf can't rewrite Zig 0.16 ELFs
							# (page-size assertion). Wrap binaries with Nix's loader.
							zig build test-compile
							zig build
							${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
							DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
							# Wrap any installed exe under zig-out so tests that exec
							# them via realPath go through Nix's loader.
							wrap_exe() {
								local bin="$1"
								[ -f "$bin" ] || return 0
								[ -x "$bin" ] || return 0
								local real="$bin.real"
								mv "$bin" "$real"
								printf "%s\n%s\n" "#!${pkgs.runtimeShell}" "exec $DL \"$real\" \"\$@\"" > "$bin"
								chmod +x "$bin"
							}
							wrap_exe zig-out/bin/par2z-cli
							wrap_exe zig-out/par2z/bin/prng-gen
							wrap_exe zig-out/par2z/bin/shared-test
							# Run the test binary directly via the loader.
							"$DL" zig-out/par2z/bin/test
							''}
							${pkgs.lib.optionalString (!pkgs.stdenv.isLinux) ''
							zig-out/par2z/bin/test
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
