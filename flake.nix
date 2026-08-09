{
  description = "lookit — cursor-following zoom for OBS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.swiftformat
            pkgs.jq
            # Quartz bindings: used to probe CGWindowList bounds while
            # verifying the stale-window-id question (DESIGN.md, open Q1).
            (pkgs.python3.withPackages (ps: [ ps.pyobjc-framework-Quartz ]))
          ];

          # Swift itself comes from the system toolchain, not nixpkgs: this is a
          # macOS-only app linking AppKit and Carbon, and the Xcode SDK is the
          # only thing that reliably provides those.
          #
          # nixpkgs pulls in an xcbuild `xcrun` shim and points DEVELOPER_DIR and
          # SDKROOT at its own apple-sdk. /usr/bin/swift resolves its toolchain
          # through those, finds no swift there, and dies with "tool 'swift' not
          # found". Clearing them hands the lookup back to the real Xcode.
          shellHook = ''
            unset DEVELOPER_DIR SDKROOT

            if ! swift --version >/dev/null 2>&1; then
              echo "lookit: swift is not runnable — install the Xcode command line tools" >&2
            fi
          '';
        };
      });
    };
}
