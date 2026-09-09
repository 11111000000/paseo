{
  description = "Paseo - self-hosted daemon for AI coding agents";

  inputs = {
    # nixos-25.11 — release branch (Q4 2025). Matches the host NixOS version.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };

      # Android SDK FOD — Expo SDK 54 requirements:
      #   compileSdkVersion = 35
      #   targetSdkVersion  = 35
      #   buildToolsVersion = 35.0.0
      #   ndkVersion        = 27.0.12077973 (per packages/app/.tool-versions)
      # Compose once per system, reuse across outputs to avoid duplicate FOD work.
      androidSdkFor =
        pkgs:
        pkgs.androidenv.composeAndroidPackages {
          abiVersions = [ "arm64-v8a" "x86_64" ];
          platformVersions = [ "35" ];
          buildToolsVersions = [ "35.0.0" ];
          includeNDK = true;
          ndkVersion = "27.0.12077973";
          includeEmulator = false;
          includeSystemImages = false;
          includeSources = false;
        };

      # Host libraries needed by the JDK / gradle / native node modules
      # inside the sandboxed devShell. Without these, gradle and
      # autoPatchelfHook fail at runtime with missing libfontconfig / libfreetype.
      hostLibsFor =
        pkgs:
        pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.fontconfig
          pkgs.freetype
          pkgs.glib
          pkgs.zlib
          pkgs.stdenv.cc.cc.lib
        ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          paseo = pkgs.callPackage ./nix/package.nix { };
          versionParts = pkgs.lib.splitString "." paseo.version;
          sourceRevision = if self ? revCount && self.revCount != null then self.revCount else 0;
          buildRevision = sourceRevision - (sourceRevision / 10000) * 10000;
          desktopBuildVersion = pkgs.lib.concatStringsSep "." [
            (builtins.elemAt versionParts 0)
            (builtins.elemAt versionParts 1)
            (toString buildRevision)
          ];
        in
        {
          default = paseo;
          paseo = paseo;
          desktop = pkgs.callPackage ./nix/desktop-package.nix {
            inherit paseo;
            buildVersion = desktopBuildVersion;
          };
        }
      );

      nixosModules.default = self.nixosModules.paseo;
      nixosModules.paseo =
        { pkgs, lib, ... }:
        {
          imports = [ ./nix/module.nix ];
          services.paseo.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          isLinux = pkgs.stdenv.hostPlatform.isLinux;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
        in
        {
          # Full Android devShell — build the Expo APK locally without EAS cloud.
          #
          # Usage:
          #   nix develop path:/home/az/Projects/paseo
          #   cd packages/app
          #   APP_VARIANT=development npm run android:development
          #
          # First `nix develop` builds the Android SDK FOD (~2-3 GB in /nix/store).
          # Subsequent shells reuse the cached derivation.
          default = pkgs.mkShell {
            packages =
              [
                pkgs.nodejs_22
                pkgs.jdk21
                pkgs.gradle
                pkgs.git
                pkgs.pkg-config
                pkgs.openssl
                pkgs.bashInteractive
                pkgs.coreutils
                pkgs.findutils
                pkgs.gnused
                pkgs.gnugrep
                pkgs.which
              ]
              ++ pkgs.lib.optionals isLinux (
                let
                  sdk = androidSdkFor pkgs;
                in
                [
                  sdk.androidsdk
                  sdk.platform-tools
                  pkgs.android-tools
                ]
                ++ sdk.ndk-bundles
              )
              ++ hostLibsFor pkgs
              ++ pkgs.lib.optionals isDarwin [
                pkgs.darwin.cctools
              ];

            # Android SDK + JDK wiring. Compose path explicitly so gradle's
            # ANDROID_SDK_ROOT autodetection works in `expo prebuild`.
            shellHook = pkgs.lib.optionalString isLinux ''
              export ANDROID_SDK_ROOT="${(androidSdkFor pkgs).androidsdk.out}"
              export ANDROID_HOME="$ANDROID_SDK_ROOT"
              export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/build-tools/35.0.0:$PATH"
              export JAVA_HOME="${pkgs.jdk21}/lib/openjdk"
              export JDK_HOME="$JAVA_HOME"
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (hostLibsFor pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              echo "[paseo-flake] Android SDK: $ANDROID_SDK_ROOT"
              echo "[paseo-flake] JDK: $JAVA_HOME"
            '' + pkgs.lib.optionalString isDarwin ''
              export JAVA_HOME="${pkgs.jdk21}/Contents/Home"
              export JDK_HOME="$JAVA_HOME"
              export PATH="$JAVA_HOME/bin:$PATH"
            '';
          };
        }
      );
    };
}
