{ config, options, lib, diskoLib, ... }:
{
  options = {
    name = lib.mkOption {
      type = lib.types.str;
      default = config._module.args.name;
      description = "Name of the volume group";
    };
    type = lib.mkOption {
      type = lib.types.enum [ "lvm_vg" ];
      internal = true;
      description = "Type";
    };
    lvs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }@lv: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Name of the logical volume";
          };
          size = lib.mkOption {
            type = lib.types.str; # TODO lvm size type
            description = "Size of the logical volume";
          };
          lvm_type = lib.mkOption {
            # TODO: add raid10
            type = lib.types.nullOr (lib.types.enum [ "mirror" "raid0" "raid1" "raid4" "raid5" "raid6" "thin-pool" "thinlv" ]); # TODO add all lib.types
            default = null; # maybe there is always a default type?
            description = "LVM type";
          };
          extraArgs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Extra arguments";
          };
          pool = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Pool LV this LV is part of";
          };
          priority = lib.mkOption {
            type = lib.types.int;
            default = (if lv.config.lvm_type == "thin-pool" then 501 else 1000) + (if lib.hasInfix "100%" lv.config.size then 251 else 0);
            description = "Priority when creating LVs. Lower priority gets created first.";
          };
          content = diskoLib.partitionType { parent = config; device = "/dev/${config.name}/${lv.config.name}"; };
        };
      }));
      default = { };
      description = "LVS for the volume group";
    };
    _meta = lib.mkOption {
      internal = true;
      readOnly = true;
      type = diskoLib.jsonType;
      default =
        diskoLib.deepMergeMap
          (lv:
            lib.optionalAttrs (lv.content != null) (lv.content._meta [ "lvm_vg" config.name ])
          )
          (lib.attrValues config.lvs);
      description = "Metadata";
    };
    _create = diskoLib.mkCreateOption {
      inherit config options;
      default =
        let
          sortedLvs = lib.sort (a: b: a.priority < b.priority) (lib.attrValues config.lvs);
        in
        ''
          readarray -t lvm_devices < <(cat "$disko_devices_dir"/lvm_${config.name})
          vgcreate ${config.name} \
            "''${lvm_devices[@]}"
          ${lib.concatMapStrings (lv: ''
            lvcreate \
              --yes \
              ${if (lv.lvm_type != "thinlv") then
                (if lib.hasInfix "%" lv.size then "-l" else "-L")
                else "-V"} ${lv.size} \
              -n ${lv.name} \
              ${lib.optionalString (lv.lvm_type == "thinlv") "--thinpool=${lv.pool}"} \
              ${lib.optionalString (lv.lvm_type != null && lv.lvm_type != "thinlv") "--type=${lv.lvm_type}"} \
              ${toString lv.extraArgs} \
              ${config.name}
            ${lib.optionalString (lv.content != null) lv.content._create}
          '') sortedLvs}
        '';
    };
    _mount = diskoLib.mkMountOption {
      inherit config options;
      default =
        let
          lvMounts = diskoLib.deepMergeMap
            (lv:
              lib.optionalAttrs (lv.content != null) lv.content._mount
            )
            (lib.attrValues config.lvs);
        in
        {
          dev = ''
            vgchange -a y
            ${lib.concatMapStrings (x: x.dev or "") (lib.attrValues lvMounts)}
          '';
          fs = lvMounts.fs or { };
        };
    };
    _config = lib.mkOption {
      internal = true;
      readOnly = true;
      default =
        map
          (lv: [
            (lib.optional (lv.content != null) lv.content._config)
            (lib.optional (lv.lvm_type != null) {
              boot.initrd.kernelModules = [(if lv.lvm_type == "mirror" then "dm-mirror" else "dm-raid")]
                ++ lib.optional (lv.lvm_type == "raid0") "raid0"
                ++ lib.optional (lv.lvm_type == "raid1") "raid1"
                # ++ lib.optional (lv.lvm_type == "raid10") "raid10"
                ++ lib.optional (lv.lvm_type == "raid4" ||
                                 lv.lvm_type == "raid5" ||
                                 lv.lvm_type == "raid6") "raid456";

            })
          ])
          (lib.attrValues config.lvs);
      description = "NixOS configuration";
    };
    _pkgs = lib.mkOption {
      internal = true;
      readOnly = true;
      type = lib.types.functionTo (lib.types.listOf lib.types.package);
      default = pkgs: lib.flatten (map
        (lv:
          lib.optional (lv.content != null) (lv.content._pkgs pkgs)
        )
        (lib.attrValues config.lvs));
      description = "Packages";
    };
  };
}
