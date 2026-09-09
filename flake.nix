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
      #   ndkVersion        = 27.1.12297006 (hardcoded default in
      #                       expo-modules-autolinking ExpoRootProjectPlugin,
      #                       see node_modules/expo-modules-autolinking/
      #                       android/expo-gradle-plugin/.../ExpoRootProjectPlugin.kt)
      #
      # Compose once per system, reuse across outputs to avoid duplicate FOD work.
      rawAndroidSdkFor =
        pkgs:
        pkgs.androidenv.composeAndroidPackages {
          abiVersions = [ "arm64-v8a" "x86_64" ];
          platformVersions = [ "35" ];
          buildToolsVersions = [ "35.0.0" ];
          includeNDK = true;
          ndkVersion = "27.1.12297006";
          includeEmulator = false;
          includeSystemImages = false;
          includeSources = false;
        };

      # Re-layout the Nix-managed Android SDK into the canonical
      # `$ANDROID_HOME/{platforms,build-tools,platform-tools,ndk/<version>}`
      # layout that the Android Gradle Plugin expects.
      #
      # `pkgs.androidenv.composeAndroidPackages` puts the SDK at
      # `$out/libexec/android-sdk/...` (Nix-FHS style), but AGP searches
      # `$ANDROID_HOME/ndk/<version>/source.properties` directly. Without
      # this re-layout, gradle downloads a side-by-side copy of the NDK
      # into `$ANDROID_HOME/ndk/`, wasting ~800 MB and requiring a fresh
      # license accept. The wrapper derivation symlinks everything into the
      # layout gradle wants.
      androidSdkFor =
        pkgs:
        let
          raw = rawAndroidSdkFor pkgs;
          ndkVersion = "27.1.12297006";
          ndkSrc = "${(builtins.head raw.ndk-bundles)}/libexec/android-sdk/ndk/${ndkVersion}";
        in
        pkgs.runCommand "android-sdk-gradle-layout"
          {
            inherit ndkVersion;
            meta = {
              description = "Android SDK re-laid out for the Android Gradle Plugin";
              platforms = raw.androidsdk.meta.platforms or [ ];
            };
          }
          ''
            mkdir -p "$out"
            # Link the platforms, build-tools, platform-tools, cmdline-tools,
            # licenses etc. that AGP looks up via $ANDROID_HOME/...
            for entry in ${raw.androidsdk}/libexec/android-sdk/*; do
              if [ "$(basename "$entry")" = ndk ]; then continue; fi
              ln -s "$entry" "$out/$(basename "$entry")"
            done
            # Lay out the NDK at the exact path AGP expects.
            mkdir -p "$out/ndk"
            ln -s "${ndkSrc}" "$out/ndk/${ndkVersion}"
            # Verify the layout so misconfigurations fail loudly at build time.
            test -f "$out/ndk/${ndkVersion}/source.properties" || {
              echo "ERROR: NDK source.properties missing at $out/ndk/${ndkVersion}/source.properties" >&2
              exit 1
            }
            test -d "$out/platforms/android-35" || {
              echo "ERROR: platforms/android-35 missing" >&2
              exit 1
            }
            test -d "$out/build-tools/35.0.0" || {
              echo "ERROR: build-tools/35.0.0 missing" >&2
              exit 1
            }
          '';

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
                  raw = rawAndroidSdkFor pkgs;
                in
                [
                  (androidSdkFor pkgs)
                  raw.platform-tools
                  pkgs.android-tools
                ]
                ++ raw.ndk-bundles
              )
              ++ hostLibsFor pkgs
              ++ pkgs.lib.optionals isDarwin [
                pkgs.darwin.cctools
              ];

            # Android SDK + JDK wiring. Compose path explicitly so gradle's
            # ANDROID_SDK_ROOT autodetection works in `expo prebuild`.
            shellHook = pkgs.lib.optionalString isLinux ''
              export ANDROID_SDK_ROOT="${androidSdkFor pkgs}"
              export ANDROID_HOME="$ANDROID_SDK_ROOT"
              export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/build-tools/35.0.0:$PATH"
              export JAVA_HOME="${pkgs.jdk21}/lib/openjdk"
              export JDK_HOME="$JAVA_HOME"
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (hostLibsFor pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              echo "[paseo-flake] Android SDK: $ANDROID_SDK_ROOT"
              echo "[paseo-flake] NDK: \$(ls -d $ANDROID_SDK_ROOT/ndk/* 2>/dev/null | head -1)"
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
