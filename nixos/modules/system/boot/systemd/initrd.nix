{ lib, config, utils, pkgs, ... }:

with lib;

let
  inherit (utils) systemdUtils escapeSystemdPath;
  inherit (systemdUtils.lib)
    generateUnits
    pathToUnit
    serviceToUnit
    sliceToUnit
    socketToUnit
    targetToUnit
    timerToUnit
    mountToUnit
    automountToUnit;


  cfg = config.boot.initrd.systemd;

  # Copied from fedora
  upstreamUnits = [
    "basic.target"
    "ctrl-alt-del.target"
    "emergency.service"
    "emergency.target"
    "final.target"
    "halt.target"
    "initrd-cleanup.service"
    "initrd-fs.target"
    "initrd-parse-etc.service"
    "initrd-root-device.target"
    "initrd-root-fs.target"
    "initrd-switch-root.service"
    "initrd-switch-root.target"
    "initrd.target"
    "initrd-udevadm-cleanup-db.service"
    "kexec.target"
    "kmod-static-nodes.service"
    "local-fs-pre.target"
    "local-fs.target"
    "multi-user.target"
    "paths.target"
    "poweroff.target"
    "reboot.target"
    "rescue.service"
    "rescue.target"
    "rpcbind.target"
    "shutdown.target"
    "sigpwr.target"
    "slices.target"
    "sockets.target"
    "swap.target"
    "sysinit.target"
    "sys-kernel-config.mount"
    "syslog.socket"
    "systemd-ask-password-console.path"
    "systemd-ask-password-console.service"
    "systemd-fsck@.service"
    "systemd-halt.service"
    "systemd-hibernate-resume@.service"
    "systemd-journald-audit.socket"
    "systemd-journald-dev-log.socket"
    "systemd-journald.service"
    "systemd-journald.socket"
    "systemd-kexec.service"
    "systemd-modules-load.service"
    "systemd-poweroff.service"
    "systemd-random-seed.service"
    "systemd-reboot.service"
    "systemd-sysctl.service"
    "systemd-tmpfiles-setup-dev.service"
    "systemd-tmpfiles-setup.service"
    "systemd-udevd-control.socket"
    "systemd-udevd-kernel.socket"
    "systemd-udevd.service"
    "systemd-udev-settle.service"
    "systemd-udev-trigger.service"
    "systemd-vconsole-setup.service"
    "timers.target"
    "umount.target"

    # TODO: Networking
    # "network-online.target"
    # "network-pre.target"
    # "network.target"
    # "nss-lookup.target"
    # "nss-user-lookup.target"
    # "remote-fs-pre.target"
    # "remote-fs.target"
  ] ++ cfg.additionalUpstreamUnits;

  upstreamWants = [
    "sysinit.target.wants"
  ];

  enabledUpstreamUnits = filter (n: ! elem n cfg.suppressedUnits) upstreamUnits;
  enabledUnits = filterAttrs (n: v: ! elem n cfg.suppressedUnits) cfg.units;
  jobScripts = concatLists (mapAttrsToList (_: unit: unit.jobScripts or []) (filterAttrs (_: v: v.enable) cfg.services));

  stage1Units = generateUnits {
    type = "initrd";
    units = enabledUnits;
    upstreamUnits = enabledUpstreamUnits;
    inherit upstreamWants;
    inherit (cfg) packages package;
  };

  fileSystems = filter utils.fsNeededForBoot config.system.build.fileSystems;

  fstab = pkgs.writeText "initrd-fstab" (lib.concatMapStringsSep "\n"
    ({ fsType, mountPoint, device, options, autoFormat, autoResize, ... }@fs: let
        opts = options ++ optional autoFormat "x-systemd.makefs" ++ optional autoResize "x-systemd.growfs";
      in "${device} /sysroot${mountPoint} ${fsType} ${lib.concatStringsSep "," opts}") fileSystems);

  kernel-name = config.boot.kernelPackages.kernel.name or "kernel";
  modulesTree = config.system.modulesTree.override { name = kernel-name + "-modules"; };
  firmware = config.hardware.firmware;
  # Determine the set of modules that we need to mount the root FS.
  modulesClosure = pkgs.makeModulesClosure {
    rootModules = config.boot.initrd.availableKernelModules ++ config.boot.initrd.kernelModules;
    kernel = modulesTree;
    firmware = firmware;
    allowMissing = false;
  };

  initrdBinEnv = pkgs.buildEnv {
    name = "initrd-bin-env";
    paths = map getBin cfg.initrdBin;
    pathsToLink = ["/bin" "/sbin"];
    postBuild = concatStringsSep "\n" (mapAttrsToList (n: v: "ln -s '${v}' $out/bin/'${n}'") cfg.extraBin);
  };

  initialRamdisk = pkgs.makeInitrdNG {
    contents = map (path: { object = path; symlink = ""; }) (subtractLists cfg.suppressedStorePaths cfg.storePaths)
      ++ mapAttrsToList (_: v: { object = v.source; symlink = v.target; }) (filterAttrs (_: v: v.enable) cfg.contents);
  };

in {
  options.boot.initrd.systemd = {
    enable = mkEnableOption ''systemd in initrd.

      Note: This is in very early development and is highly
      experimental. Most of the features NixOS supports in initrd are
      not yet supported by the intrd generated with this option.
    '';

    package = (mkPackageOption pkgs "systemd" {
      default = "systemdStage1";
    }) // {
      visible = false;
    };

    contents = mkOption {
      description = "Set of files that have to be linked into the initrd";
      example = literalExpression ''
        {
          "/etc/hostname".text = "mymachine";
        }
      '';
      visible = false;
      default = {};
      type = types.attrsOf (types.submodule ({ config, options, name, ... }: {
        options = {
          enable = mkEnableOption "copying of this file to initrd and symlinking it" // { default = true; };

          target = mkOption {
            type = types.path;
            description = ''
              Path of the symlink.
            '';
            default = name;
          };

          text = mkOption {
            default = null;
            type = types.nullOr types.lines;
            description = "Text of the file.";
          };

          source = mkOption {
            type = types.path;
            description = "Path of the source file.";
          };
        };

        config = {
          source = mkIf (config.text != null) (
            let name' = "initrd-" + baseNameOf name;
            in mkDerivedConfig options.text (pkgs.writeText name')
          );
        };
      }));
    };

    storePaths = mkOption {
      description = ''
        Store paths to copy into the initrd as well.
      '';
      type = types.listOf types.singleLineStr;
      default = [];
    };

    extraBin = mkOption {
      description = ''
        Tools to add to /bin
      '';
      example = literalExpression ''
        {
          umount = ''${pkgs.util-linux}/bin/umount;
        }
      '';
      type = types.attrsOf types.path;
      default = {};
    };

    suppressedStorePaths = mkOption {
      description = ''
        Store paths specified in the storePaths option that
        should not be copied.
      '';
      type = types.listOf types.singleLineStr;
      default = [];
    };

    emergencyAccess = mkOption {
      type = with types; oneOf [ bool singleLineStr ];
      visible = false;
      description = ''
        Set to true for unauthenticated emergency access, and false for
        no emergency access.

        Can also be set to a hashed super user password to allow
        authenticated access to the emergency mode.
      '';
      default = false;
    };

    initrdBin = mkOption {
      type = types.listOf types.package;
      default = [];
      visible = false;
      description = ''
        Packages to include in /bin for the stage 1 emergency shell.
      '';
    };

    additionalUpstreamUnits = mkOption {
      default = [ ];
      type = types.listOf types.str;
      visible = false;
      example = [ "debug-shell.service" "systemd-quotacheck.service" ];
      description = ''
        Additional units shipped with systemd that shall be enabled.
      '';
    };

    suppressedUnits = mkOption {
      default = [ ];
      type = types.listOf types.str;
      example = [ "systemd-backlight@.service" ];
      visible = false;
      description = ''
        A list of units to skip when generating system systemd configuration directory. This has
        priority over upstream units, <option>boot.initrd.systemd.units</option>, and
        <option>boot.initrd.systemd.additionalUpstreamUnits</option>. The main purpose of this is to
        prevent a upstream systemd unit from being added to the initrd with any modifications made to it
        by other NixOS modules.
      '';
    };

    units = mkOption {
      description = "Definition of systemd units.";
      default = {};
      visible = false;
      type = systemdUtils.types.units;
    };

    packages = mkOption {
      default = [];
      visible = false;
      type = types.listOf types.package;
      example = literalExpression "[ pkgs.systemd-cryptsetup-generator ]";
      description = "Packages providing systemd units and hooks.";
    };

    targets = mkOption {
      default = {};
      visible = false;
      type = systemdUtils.types.initrdTargets;
      description = "Definition of systemd target units.";
    };

    services = mkOption {
      default = {};
      type = systemdUtils.types.initrdServices;
      visible = false;
      description = "Definition of systemd service units.";
    };

    sockets = mkOption {
      default = {};
      type = systemdUtils.types.initrdSockets;
      visible = false;
      description = "Definition of systemd socket units.";
    };

    timers = mkOption {
      default = {};
      type = systemdUtils.types.initrdTimers;
      visible = false;
      description = "Definition of systemd timer units.";
    };

    paths = mkOption {
      default = {};
      type = systemdUtils.types.initrdPaths;
      visible = false;
      description = "Definition of systemd path units.";
    };

    mounts = mkOption {
      default = [];
      type = systemdUtils.types.initrdMounts;
      visible = false;
      description = ''
        Definition of systemd mount units.
        This is a list instead of an attrSet, because systemd mandates the names to be derived from
        the 'where' attribute.
      '';
    };

    automounts = mkOption {
      default = [];
      type = systemdUtils.types.automounts;
      visible = false;
      description = ''
        Definition of systemd automount units.
        This is a list instead of an attrSet, because systemd mandates the names to be derived from
        the 'where' attribute.
      '';
    };

    slices = mkOption {
      default = {};
      type = systemdUtils.types.slices;
      visible = false;
      description = "Definition of slice configurations.";
    };
  };

  config = mkIf (config.boot.initrd.enable && cfg.enable) {
    system.build = { inherit initialRamdisk; };

    boot.initrd.availableKernelModules = [ "autofs4" ]; # systemd needs this for some features

    boot.initrd.systemd = {
      initrdBin = [pkgs.bash pkgs.coreutils cfg.package.kmod cfg.package] ++ config.system.fsPackages;
      extraBin = {
        less = "${pkgs.less}/bin/less";
        mount = "${cfg.package.util-linux}/bin/mount";
        umount = "${cfg.package.util-linux}/bin/umount";
      };

      contents = {
        "/init".source = "${cfg.package}/lib/systemd/systemd";
        "/etc/systemd/system".source = stage1Units;

        "/etc/systemd/system.conf".text = ''
          [Manager]
          DefaultEnvironment=PATH=/bin:/sbin ${optionalString (isBool cfg.emergencyAccess && cfg.emergencyAccess) "SYSTEMD_SULOGIN_FORCE=1"}
        '';

        "/etc/fstab".source = fstab;

        "/lib/modules".source = "${modulesClosure}/lib/modules";

        "/etc/modules-load.d/nixos.conf".text = concatStringsSep "\n" config.boot.initrd.kernelModules;

        "/etc/passwd".source = "${pkgs.fakeNss}/etc/passwd";
        "/etc/shadow".text = "root:${if isBool cfg.emergencyAccess then "!" else cfg.emergencyAccess}:::::::";

        "/bin".source = "${initrdBinEnv}/bin";
        "/sbin".source = "${initrdBinEnv}/sbin";

        "/etc/sysctl.d/nixos.conf".text = "kernel.modprobe = /sbin/modprobe";
        "/etc/modprobe.d/systemd.conf".source = "${cfg.package}/lib/modprobe.d/systemd.conf";
      };

      storePaths = [
        # systemd tooling
        "${cfg.package}/lib/systemd/systemd-fsck"
        "${cfg.package}/lib/systemd/systemd-growfs"
        "${cfg.package}/lib/systemd/systemd-hibernate-resume"
        "${cfg.package}/lib/systemd/systemd-journald"
        "${cfg.package}/lib/systemd/systemd-makefs"
        "${cfg.package}/lib/systemd/systemd-modules-load"
        "${cfg.package}/lib/systemd/systemd-random-seed"
        "${cfg.package}/lib/systemd/systemd-remount-fs"
        "${cfg.package}/lib/systemd/systemd-shutdown"
        "${cfg.package}/lib/systemd/systemd-sulogin-shell"
        "${cfg.package}/lib/systemd/systemd-sysctl"
        "${cfg.package}/lib/systemd/systemd-udevd"
        "${cfg.package}/lib/systemd/systemd-vconsole-setup"

        # additional systemd directories
        "${cfg.package}/lib/systemd/system-generators"
        "${cfg.package}/lib/udev"

        # utilities needed by systemd
        "${cfg.package.util-linux}/bin/mount"
        "${cfg.package.util-linux}/bin/umount"
        "${cfg.package.util-linux}/bin/sulogin"

        # so NSS can look up usernames
        "${pkgs.glibc}/lib/libnss_files.so.2"
      ] ++ jobScripts;

      targets.initrd.aliases = ["default.target"];
      units =
           mapAttrs' (n: v: nameValuePair "${n}.path"    (pathToUnit    n v)) cfg.paths
        // mapAttrs' (n: v: nameValuePair "${n}.service" (serviceToUnit n v)) cfg.services
        // mapAttrs' (n: v: nameValuePair "${n}.slice"   (sliceToUnit   n v)) cfg.slices
        // mapAttrs' (n: v: nameValuePair "${n}.socket"  (socketToUnit  n v)) cfg.sockets
        // mapAttrs' (n: v: nameValuePair "${n}.target"  (targetToUnit  n v)) cfg.targets
        // mapAttrs' (n: v: nameValuePair "${n}.timer"   (timerToUnit   n v)) cfg.timers
        // listToAttrs (map
                     (v: let n = escapeSystemdPath v.where;
                         in nameValuePair "${n}.mount" (mountToUnit n v)) cfg.mounts)
        // listToAttrs (map
                     (v: let n = escapeSystemdPath v.where;
                         in nameValuePair "${n}.automount" (automountToUnit n v)) cfg.automounts);

      # The unit in /run/systemd/generator shadows the unit in
      # /etc/systemd/system, but will still apply drop-ins from
      # /etc/systemd/system/foo.service.d/
      #
      # We need IgnoreOnIsolate, otherwise the Requires dependency of
      # a mount unit on its makefs unit causes it to be unmounted when
      # we isolate for switch-root. Use a dummy package so that
      # generateUnits will generate drop-ins instead of unit files.
      packages = [(pkgs.runCommand "dummy" {} ''
        mkdir -p $out/etc/systemd/system
        touch $out/etc/systemd/system/systemd-{makefs,growfs}@.service
      '')];
      services."systemd-makefs@".unitConfig.IgnoreOnIsolate = true;
      services."systemd-growfs@".unitConfig.IgnoreOnIsolate = true;

      services.initrd-nixos-activation = {
        after = [ "initrd-fs.target" ];
        requiredBy = [ "initrd.target" ];
        unitConfig.AssertPathExists = "/etc/initrd-release";
        serviceConfig.Type = "oneshot";
        description = "NixOS Activation";

        script = /* bash */ ''
          set -uo pipefail
          export PATH="/bin:${cfg.package.util-linux}/bin"

          # Figure out what closure to boot
          closure=
          for o in $(< /proc/cmdline); do
              case $o in
                  init=*)
                      IFS== read -r -a initParam <<< "$o"
                      closure="$(dirname "''${initParam[1]}")"
                      ;;
              esac
          done

          # Sanity check
          if [ -z "''${closure:-}" ]; then
            echo 'No init= parameter on the kernel command line' >&2
            exit 1
          fi

          # If we are not booting a NixOS closure (e.g. init=/bin/sh),
          # we don't know what root to prepare so we don't do anything
          if ! [ -x "/sysroot$closure/prepare-root" ]; then
            echo "NEW_INIT=''${initParam[1]}" > /etc/switch-root.conf
            echo "$closure does not look like a NixOS installation - not activating"
            exit 0
          fi
          echo 'NEW_INIT=' > /etc/switch-root.conf


          # We need to propagate /run for things like /run/booted-system
          # and /run/current-system.
          mkdir -p /sysroot/run
          mount --bind /run /sysroot/run

          # Initialize the system
          export IN_NIXOS_SYSTEMD_STAGE1=true
          exec chroot /sysroot $closure/prepare-root
        '';
      };

      # This will either call systemctl with the new init as the last parameter (which
      # is the case when not booting a NixOS system) or with an empty string, causing
      # systemd to bypass its verification code that checks whether the next file is a systemd
      # and using its compiled-in value
      services.initrd-switch-root.serviceConfig = {
        EnvironmentFile = "-/etc/switch-root.conf";
        ExecStart = [
          ""
          ''systemctl --no-block switch-root /sysroot "''${NEW_INIT}"''
        ];
      };
    };
  };
}
