{
	description = "par2-cleanroom dev shell";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
			forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
		in {
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
							mktmpPkg
						] ++ linuxOnly ++ pkgs.lib.optional (valgrindPkg != null) valgrindPkg;

						shellHook = ''
							echo "par2-cleanroom dev shell: zig/zls/afl++/par2cmdline"
						'';
					};
				});
		};
}
