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

      # Android SDK FOD — Expo SDK 54 + react-native-unistyles 3.x:
      #   compileSdkVersion = 35
      #   targetSdkVersion  = 35
      #   buildToolsVersion = 35.0.0
      #   ndkVersion (Expo autolinking) = 27.1.12297006
      #   ndkVersion (react-native-unistyles fallback) = 27.0.12077973
      #
      # Expo SDK 54 hardcodes 27.1.12297006 in
      # `expo-modules-autolinking/android/expo-gradle-plugin/.../ExpoRootProjectPlugin.kt`.
      # But at least one transitive dep (`react-native-unistyles` 3.x as
      # pinned by Paseo) still requests 27.0.12077973 from the Android
      # Gradle Plugin, which then tries to *install* it into ANDROID_HOME
      # — and fails because the Nix store is read-only.
      #
      # Workaround: include both NDKs in the SDK FOD. AGP picks the
      # version each module asks for and never tries to install.
      rawAndroidSdkFor =
        pkgs:
        pkgs.androidenv.composeAndroidPackages {
          abiVersions = [ "arm64-v8a" "x86_64" ];
          platformVersions = [ "35" ];
          buildToolsVersions = [ "35.0.0" ];
          includeNDK = true;
          ndkVersions = [ "27.1.12297006" "27.0.12077973" ];
          includeEmulator = false;
          includeSystemImages = false;
          includeSources = false;
        };

      # The Nix-managed Android SDK is at
      # `${raw.androidsdk}/libexec/android-sdk/`, which puts the platforms,
      # build-tools, platform-tools, and NDK in sub-paths that don't match
      # the Android Gradle Plugin's expectations. AGP searches
      # `$ANDROID_HOME/ndk/<version>/source.properties` directly.
      #
      # We point `ANDROID_SDK_ROOT` at the inner `android-sdk/` directory
      # and patch the NDK layout at runtime in the shellHook (see below).
      # We do NOT wrap it in a `runCommand` derivation because the NDK
      # multi-output derivations compose badly as nativeBuildInputs of a
      # `mkShell` derivation ("cannot coerce a list to a string").
      #
      # Returns the inner `android-sdk/` path that AGP can consume
      # directly, plus a `ndkVersions` list for the shellHook.
      androidSdkDirFor =
        pkgs: rawAndroidSdkFor pkgs;
      ndkVersionList = [ "27.1.12297006" "27.0.12077973" ];

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
                  raw = androidSdkDirFor pkgs;
                in
                [
                  raw.androidsdk
                  raw.platform-tools
                  pkgs.android-tools
                ]
                # NDK derivations are intentionally NOT in `packages` —
                # they're multi-output and don't compose cleanly as
                # nativeBuildInputs of a mkShell derivation. The
                # shellHook below re-lays them out under
                # `$ANDROID_HOME/ndk/<version>/` at runtime, which is
                # exactly the path AGP searches.
              )
              ++ hostLibsFor pkgs
              ++ pkgs.lib.optionals isDarwin [
                pkgs.darwin.cctools
              ];

            # Android SDK + JDK wiring. Compose path explicitly so gradle's
            # ANDROID_SDK_ROOT autodetection works in `expo prebuild`.
            #
            # Two AGP layout mismatches to fix at runtime:
            #   1. ANDROID_HOME points into `$out/libexec/android-sdk/`
            #      (Nix-FHS style); AGP searches `$ANDROID_HOME/<dir>`
            #      directly, so we use the inner `android-sdk/` path.
            #   2. NDK is missing from the inner layout; lay it out as
            #      `$ANDROID_HOME/ndk/<version>/source.properties`.
            shellHook = pkgs.lib.optionalString isLinux ''
              export ANDROID_SDK_ROOT="${(androidSdkDirFor pkgs).androidsdk}/libexec/android-sdk"
              export ANDROID_HOME="$ANDROID_SDK_ROOT"
              # Lay out every requested NDK at the path AGP expects.
              if [ ! -e "$ANDROID_HOME/ndk" ]; then
                mkdir -p "$ANDROID_HOME/ndk"
              fi
              for version in ${pkgs.lib.concatStringsSep " " ndkVersionList}; do
                ndk_store="$(find /nix/store -maxdepth 1 -name "android-sdk-ndk-$version" -type d 2>/dev/null | head -1)"
                if [ -n "$ndk_store" ] && [ ! -e "$ANDROID_HOME/ndk/$version" ]; then
                  ln -s "$ndk_store/libexec/android-sdk/ndk/$version" "$ANDROID_HOME/ndk/$version"
                fi
              done
              export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/build-tools/35.0.0:$PATH"
              export JAVA_HOME="${pkgs.jdk21}/lib/openjdk"
              export JDK_HOME="$JAVA_HOME"
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (hostLibsFor pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              echo "[paseo-flake] Android SDK: $ANDROID_SDK_ROOT"
              echo "[paseo-flake] NDK versions: $(ls -d $ANDROID_HOME/ndk/* 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
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
