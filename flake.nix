{
  description = "Reckonim - probabilistic judgment layer for Nim over TypeSafe Jev";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.nim pkgs.nimble pkgs.nimlangserver ];

          # -d:ssl links -lssl -lcrypto, so openssl must be a buildInput (puts it
          # in NIX_LDFLAGS) and not just on LD_LIBRARY_PATH.
          buildInputs = [ pkgs.openssl ];

          # ponytail: nimble writes here; keeping it in-tree avoids polluting $HOME
          # and makes the checkout self-contained. Drop if you want the global cache.
          shellHook = ''
            export NIMBLE_DIR="$PWD/.nimble"
          '';
        };
      });
    };
}
