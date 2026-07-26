{
  inputs = {
    # What version from nixpks to use. I like living on the edge.
    # See other "channels" https://nixos.org/manual/nixos/unstable/#sec-upgrading
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # We can pull from more than one source! Let's get some helpers for
    # flake users
    flake-utils.url = "github:numtide/flake-utils";
    # nixpkgs offers a rust compiler, but I prefer using oxalica's overlay since
    # it offers more control
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };
  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    # In this case, we support linux in these two architectures
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ]
      (system:
        let
          overlays = [ (import rust-overlay) ];
          pkgs = import nixpkgs {
            inherit system overlays;
          };
          llvm' = pkgs.llvmPackages_21;
          # We don't need debuginfod support, let's disable it and also get rid
          # of zstd below since it's no longer needed
          elfutils' = (pkgs.elfutils.override { enableDebuginfod = true; }).overrideAttrs (attrs: {
            doCheck = false;
            doInstallCheck = false;
            configureFlags = attrs.configureFlags ++ [ "--without-zstd" ];
            nativeBuildInputs = attrs.nativeBuildInputs ++ [ pkgs.pkg-config ];
          });
          # Nix provided `clang` adds some compilation options that can't be used for BPF.
          clang' = with pkgs; (
            pkgs.writeShellScriptBin "clang" ''
              if [[ "$@" =~ "-target bpf" ]]; then
                exec ${llvm'.clang-unwrapped}/bin/clang -I${llvmPackages_21.clang-unwrapped.lib}/lib/clang/21/include "$@"
              else
                exec ${llvm'.clang}/bin/clang "$@"
              fi
            ''
          );
          buildInputs = with pkgs; [
            clang'
            llvm'.libcxx
            # Used by bindgen
            llvm'.libclang
            llvm'.lld
            elfutils'
            zlib.static
            zlib.dev
          ];
          nativeBuildInputs = with pkgs; [
            pkg-config
          ];
          rust-toolchain = pkgs.rust-bin.nightly.latest.default;
        in
        with pkgs;
        {
          formatter = pkgs.nixpkgs-fmt;
          devShells.default = mkShell {
            nativeBuildInputs = nativeBuildInputs;
            buildInputs = buildInputs ++ [
              # cargo, rustc, etc
              rust-toolchain
            ];
            LIBCLANG_PATH = lib.makeLibraryPath [ llvm'.libclang ];
            LIBBPF_SYS_LIBRARY_PATH = lib.makeLibraryPath [ zlib.static elfutils' ];
          };

        }
      );
}
