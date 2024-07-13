{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.virtualisation.virtualMachines;

  inherit (lib) mkIf mkOption types;
in {
  options = {
    virtualisation.virtualMachines = {
      enable = mkOption {
        type = types.bool;
        default = false;
      };
      username = mkOption { type = types.str; };

      sambaAccess = {
        enable = mkOption {
          type = types.bool;
          default = false;
        };
      };

      vmFolderPath = mkOption {
        type = types.str;
        default = "/home/${cfg.username}/VM";
      };
      isoFolderPath = mkOption {
        type = types.str;
        default = "${cfg.vmFolderPath}/ISO";
      };

      machines = mkOption {
        default = [];
        type = with types; listOf(submodule { options = {
          name = mkOption {
            type = types.str;
            default = "win11";
          };
          os = mkOption {
            type = types.str;
            default = "win11";
          };

          isoName = mkOption {
            type = types.str;
            default = "win11.iso";
          };

          hardware = {
            cores = mkOption {
              type = types.int;
              default = 2;
            };
            threads = mkOption {
              type = types.int;
              default = 2;
            };
            memory = mkOption {
              type = types.int;
              default = 8;
            };

            disk = {
              size = mkOption {
                type = types.int;
                default = 128;
              };
              path = mkOption {
                type = types.str;
                default = "${cfg.vmFolderPath}/DISK";
              };
              ssdEmulation = mkOption {
                type = types.bool;
                default = true;
              };
            };
          };

          passthrough = {
            enable = mkOption {
              type = types.bool;
              default = false;
            };

            restartDm = mkOption {
              type = types.bool;
              default = false;
            };

            pcies = mkOption {
              default = [];
              type = listOf(submodule { options = {
                lines = {
                  vmBus = mkOption {
                    type = types.str;
                    default = "09";
                  };
                  bus = mkOption {
                    type = types.str;
                    default = "";
                  };
                  slot = mkOption {
                    type = types.str;
                    default = "";
                  };
                  functions = mkOption {
                    type = listOf(types.str);
                    default = [];
                  };
                  ids = mkOption {
                    type = listOf(types.str);
                    default = [];
                  };
                };
                

                driver = mkOption {
                  type = types.str;
                  default = "";
                };

                blacklist = {
                  driver = mkOption {
                    type = types.bool;
                    default = false;
                  };
                  pcie = mkOption {
                    type = types.bool;
                    default = false;
                  };
                };
              };});
            };
          };
        };});
      };
    };
  };

  config = mkIf (cfg.enable) {
    boot = {
      initrd.kernelModules = [
        "vfio_pci"
        "vfio"
        "vfio_iommu_type1"
        "amdgpu"
      ];

      extraModprobeConfig = let
        baseConfig = ''
          options kvm_intel kvm_amd modeset=1
        '';


        vfioPciOptions = lib.concatStrings (
          builtins.map (vm:
            lib.optionalString vm.passthrough.enable
              (lib.concatStrings (lib.forEach vm.passthrough.pcies (pcie:
                lib.concatStrings (lib.forEach pcie.lines.ids (id:
                  ''
                    options vfio-pci ids=${id}
                  ''
                )))))) cfg.machines);

        pciBlacklistOptions = lib.concatStrings (
          builtins.map (vm:
            lib.optionalString vm.passthrough.enable
              (lib.concatStrings (lib.forEach vm.passthrough.pcies (pcie:
                lib.optionalString (pcie.blacklist.driver)
                  ''
                    options ${pcie.driver} modeset=0
                    blacklist ${pcie.driver}
                  '')))) cfg.machines);

      in lib.concatStrings ([
        baseConfig
        vfioPciOptions
        pciBlacklistOptions
      ]);

      kernelParams = [
        "intel_iommu=on"
        "amd_iommu=on"
        "iommu=pt"
        "video=efifb:off"
      ];
    };

    services = {
      samba = lib.mkIf cfg.sambaAccess.enable {
        openFirewall = true;
        enable = true;
        securityType = "user";

        shares = {
          home = {
            path = "/home/${cfg.username}";
            browseable = "yes";
            writeable = "yes";
            "acl allow execute always" = true;
            "read only" = "no";
            "valid users" = "${cfg.username}";
            "create mask" = "0644";
            "directory mask" = "0755";
            "force user" = "${cfg.username}";
            "force group" = "users";
          };

          media = {
            path = "/run/media/${cfg.username}";
            browseable = "yes";
            writeable = "yes";
            "acl allow execute always" = true;
            "read only" = "no";
            "valid users" = "${cfg.username}";
            "create mask" = "0644";
            "directory mask" = "0755";
            "force user" = "${cfg.username}";
            "force group" = "users";
          };
        };
      };
    };

    virtualisation = lib.mkIf cfg.enable {
      libvirtd = {
        enable = true;
        qemu = {
          package = pkgs.qemu_kvm;
          runAsRoot = true;
          swtpm.enable = true;
          ovmf = {
            enable = true;
            packages = [
              (pkgs.OVMF.override {
                secureBoot = true;
                tpmSupport = true;
              }).fd
              pkgs.virglrenderer
            ];
          };
        };
      };
    };

    environment.systemPackages = with pkgs; [
      rofi-vm
      looking-glass-client
      virt-manager
    ];

    systemd.services.libvirtd.preStart =
      lib.concatStrings (lib.forEach cfg.machines
    (vm:
      let
        ifElse = condition: resultIf: resultElse: (
          if condition
          then resultIf
          else resultElse
        );

        bindingPcie = let
          lines = lines: function: ''
            BUS="${lines.bus}"
            SLOT="${lines.slot}"
            FUNCTION="${function}"
            PCIE_FULL="$BUS:$SLOT.$FUNCTION"
            PCIE_ESCAPED="$BUS\\:$SLOT.$FUNCTION"
          '';

          unbindPciesSetter = pcie: lib.concatStrings (
            lib.forEach pcie.lines.functions (function: ''
              ${lines pcie.lines function}
              echo 0000:$PCIE_FULL \
                > /sys/bus/pci/devices/0000\:$PCIE_ESCAPED/driver/unbind \
                2> /dev/null
            '')
          );

          bindPciesSetter = pcie: lib.concatStrings (
            lib.forEach pcie.lines.functions (function: ''
              ${lines pcie.lines function}
              echo 0000:$PCIE_FULL > \
                /sys/bus/pci/drivers/${pcie.driver}/bind \
                2> /dev/null
            '')
          );

          blacklistCondition = blacklist: lib.optionalString (
            ! blacklist.driver
            && blacklist.pcie
          );

          bindingCondition = blacklist: lib.optionalString (
            ! blacklist.driver
            && ! blacklist.pcie
          );

          finalString = condition: binding: lib.optionalString vm.passthrough.enable (
            lib.concatStrings (builtins.map (pcie:
              (condition pcie.blacklist) (binding pcie)
            ) vm.passthrough.pcies)
          );

        in {
          bind = (finalString bindingCondition bindPciesSetter);
          unbind = (finalString bindingCondition unbindPciesSetter);
          blacklist = (finalString blacklistCondition unbindPciesSetter);
        };

        restartDmFormated = (lib.optionalString (
          vm.passthrough.enable
          && vm.passthrough.restartDm
        )
          "systemctl restart display-manager.service");

        pciesXml = (lib.optionalString (
          vm.passthrough.enable
        ) (
          lib.concatStrings (builtins.map (pcie: lib.concatStrings (
            lib.forEach pcie.lines.functions (function: ''
              <hostdev
                mode='subsystem'
                type='pci'
                managed='yes'
              >
                <source>
                  <address
                    domain='0x0000'
                    bus='0x${pcie.lines.bus}'
                    slot='0x${pcie.lines.slot}'
                    function='0x${function}'
                  />
                </source>
                <address
                  type='pci'
                  domain='0x0000'
                  bus='0x${pcie.lines.vmBus}'
                  slot='0x${pcie.lines.slot}'
                  function='0x${function}'
                />
                <!-- multifunction='on' -->
              </hostdev>
            '')
          )) vm.passthrough.pcies)
        ));

        videoVirtio = (ifElse (vm.passthrough.enable)
          ''
            <model type='none'/>
          ''
          ''
            <model type="virtio" heads="1" primary="yes">
              <acceleration accel3d="no"/>
            </model>
            <address
              type="pci"
              domain="0x0000"
              bus="0x00"
              slot="0x01"
              function="0x0"
            />
          '');

        graphicsVirtio = (ifElse (vm.passthrough.enable)
          ''
            <graphics type="spice" port="-1" autoport="no">
              <listen type="address"/>
              <image compression="off"/>
              <gl enable="no"/>
            </graphics>
          ''
          ''
            <graphics type='spice'>
              <listen type="none"/>
              <image compression="off"/>
              <gl enable="no"/>
            </graphics>
          '');

        ssdEmulation = (lib.optionalString vm.hardware.disk.ssdEmulation
          ''
            <qemu:override>
              <qemu:device alias="scsi0-0-0-0">
                <qemu:frontend>
                  <qemu:property name="rotation_rate" type="unsigned" value="1"/>
                </qemu:frontend>
              </qemu:device>
            </qemu:override>
          '');

        virtioIso = (lib.optionalString (vm.os == "win11") ''
          <disk type='file' device='cdrom'>
            <driver name='qemu' type='raw'/>
            <source file='${cfg.isoFolderPath}/virtio-win.iso'/>
            <target dev='sdc' bus='sata'/>
            <readonly/>
            <address type='drive' controller='0' bus='0' target='0' unit='2'/>
          </disk>
        '');

        osUrl = (ifElse (vm.os == "linux")
          "http://libosinfo.org/linux/2022"
          "http://microsoft.com/win/11");

        qemuHook = (pkgs.writeScript "qemu-hook" (
          builtins.replaceStrings [
            "{{ unbindPcies }}"
            "{{ bindPcies }}"
            "{{ restartDm }}"
            "{{ username }}"
          ] [
            (bindingPcie.unbind)
            (bindingPcie.bind)
            restartDmFormated
            (cfg.username)
          ] (builtins.readFile ./src/qemuHook.sh)
        ));

        templateConfig = (pkgs.writeText "template-config" (
          builtins.replaceStrings [
            "{{ vm.memory }}"
            "{{ vm.vcore }}"
            "{{ vm.cores }}"
            "{{ vm.threads }}"
            "{{ vm.pcies }}"
            "{{ vm.diskPath }}"
            "{{ videoVirtio }}"
            "{{ graphicsVirtio }}"
            "{{ vm.name }}"
            "{{ ssdEmulation }}"
            "{{ osUrl }}"
          ] [
            (toString vm.hardware.memory)
            (toString (vm.hardware.cores * vm.hardware.threads))
            (toString vm.hardware.cores)
            (toString vm.hardware.threads)
            pciesXml
            (vm.hardware.disk.path)
            videoVirtio
            graphicsVirtio
            (vm.name)
            ssdEmulation
            osUrl
          ] (builtins.readFile ./src/template.xml)
        ));

        templateSetupConfig = (pkgs.writeText "template-setup-config" (
          builtins.replaceStrings [
            "{{ vm.memory }}"
            "{{ vm.vcore }}"
            "{{ vm.cores }}"
            "{{ vm.threads }}"
            "{{ isoFolderPath }}"
            "{{ vm.diskPath }}"
            "{{ vm.name }}"
            "{{ ssdEmulation }}"
            "{{ virtioIso }}"
            "{{ osUrl }}"
            "{{ vm.isoName }}"
          ] [
            (toString vm.hardware.memory)
            (toString (vm.hardware.cores * vm.hardware.threads))
            (toString vm.hardware.cores)
            (toString vm.hardware.threads)
            (cfg.isoFolderPath)
            (vm.hardware.disk.path)
            (vm.name)
            ssdEmulation
            virtioIso
            osUrl
            (vm.isoName)
          ] (builtins.readFile ./src/template-setup.xml)
        ));

        pathISO = (pkgs.writeText "path-iso" (
          builtins.replaceStrings [
            "{{ isoFolderPath }}"
          ] [
            cfg.isoFolderPath
          ] (builtins.readFile ./src/ISO.xml)
        ));
      in
        ''
          ${bindingPcie.blacklist}

          mkdir -p /var/lib/libvirt/{hooks,qemu,storage}
          chmod 755 /var/lib/libvirt/{hooks,qemu,storage}

          if [ ! -f ${vm.hardware.disk.path}/${vm.name}.qcow2 ]; then
	          mkdir -p ${vm.hardware.disk.path}
            qemu-img create \
              -f qcow2 ${vm.hardware.disk.path}/${vm.name}.qcow2 \
              ${(toString vm.hardware.disk.size)}G
          fi

          # Copy hook files
          ln -sf ${qemuHook} /var/lib/libvirt/hooks/qemu.d/${vm.name}
          ln -sf ${pathISO} /var/lib/libvirt/storage/ISO.xml
          ln -sf ${templateConfig} /var/lib/libvirt/qemu/${vm.name}.xml
          ln -sf ${templateSetupConfig} /var/lib/libvirt/qemu/${vm.name}-setup.xml
        ''
    ));
  };
}
