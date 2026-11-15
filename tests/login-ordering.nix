# What a login waits for: the layer's guest units that must finish before the
# workload starts — egress-seal, work-ephemeral, workspace-guard, and the proxy
# environment when it is on — are ordered before
# systemd-user-sessions.service, which every login waits for, on whatever
# terminal it runs.
#
# They used to name getty@hvc0.service, which is one consumer's terminal and
# not even its getty: the console's comes from systemd-getty-generator as
# serial-getty@hvc0, so that ordering held nothing back and the login raced
# them. The rule is read off the evaluated config rather than a list kept here:
# no service of the layer's may order itself by a getty at all.
#
# Evaluated with both modules, in the default shape and with the proxy
# environment and the AppArmor layer on; nothing boots.
{ pkgs, lib, modules }:

let
  sessions = "systemd-user-sessions.service";

  eval = extra: (import "${pkgs.path}/nixos/lib/eval-config.nix" {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = modules ++ [
      {
        boot.loader.grub.enable = false;
        fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
        system.stateVersion = lib.trivial.release;
      }
      extra
    ];
  }).config;

  shapes = {
    default = eval { };
    proxy-env-apparmor = eval {
      microvmPolicy.egress.proxyEnvironment = true;
      microvmPolicy.workspaceGuard.apparmor.enable = true;
    };
  };

  isGetty = u: builtins.match "(serial-getty|getty|autovt|container-getty|console-getty)[@.].*" u != null;

  checksFor = shape: config:
    let
      services = config.systemd.services;
      beforeOf = s: services.${s}.before or [ ];
      wanted = [ "egress-seal" "work-ephemeral" "workspace-guard" ]
        ++ lib.optional config.microvmPolicy.egress.proxyEnvironment "egress-proxy-env";
    in
    map (s: {
      name = "${shape}: ${s} is before ${sessions}";
      ok = services ? ${s} && lib.elem sessions (beforeOf s);
    }) wanted
    ++ map (s: {
      name = "${shape}: ${s} names no getty in before=";
      ok = !(lib.any isGetty (beforeOf s));
    }) (lib.attrNames services);

  checks = lib.concatLists (lib.mapAttrsToList checksFor shapes);
  failed = lib.filter (c: !c.ok) checks;
in
pkgs.runCommand "login-ordering" { } ''
  echo ${lib.escapeShellArg "${toString (lib.length checks)} checks"}
  ${lib.concatMapStrings (c: ''
    echo ${lib.escapeShellArg "FAIL: ${c.name}"} >&2
  '') failed}
  ${if failed == [ ] then "touch $out" else "exit 1"}
''
