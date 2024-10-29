{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.virtualisation.virtualMachines;

  concatFor = array: return: (lib.concatStrings
    (map return array)  
  );

  optionalConcatFor = { condition, array, return }:
    (lib.optionalString condition
      (concatFor array return)
    );
    
  concatJoin = join: array: return: (lib.concatStringsSep join
    (map return array)  
  );

  optionalConcatJoin = { condition, array, return, join }:
    (lib.optionalString condition
      (concatJoin join array return)
    );

  exec = storeName: input: script: let
    command = (
      pkgs.runCommand "${storeName}"
        { nativeBuildInputs = input; }
        script
    );
  in (lib.readFile "${command}");

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
          uuid = mkOption {
            type = types.str;
            default = "";
          };
          uuidSetup = mkOption {
            type = types.str;
            default = "";
          };

          isoName = mkOption {
            type = types.str;
            default = "win11.iso";
          };

          lookingGlass = mkOption {
            type = types.bool;
            default = true;
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
              enable = mkOption {
                type = types.bool;
                default = true;
              };
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
                disk = mkOption {
                  type = types.bool;
                  default = false;
                };
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
                    default = [];
                    type = listOf(submodule { options = {
                      fix = {
                        rom = mkOption {
                          type = types.bool;
                          default = true;
                        };
                        
                        rebar = mkOption {
                          type = types.int;
                          default = 0;
                        };
                        
                      };

                      function = mkOption {
                        type = types.str;
                        default = "";
                      };

                      drivers = mkOption {
                        type = listOf(types.str);
                        default = [];
                      };

                      vendor = mkOption {
                        type = types.str;
                        default = "";
                      };

                      blacklist = {
                        driver = mkOption {
                          type = types.bool;
                          default = false;
                        };

                        vfioPriority = mkOption {
                          type = types.bool;
                          default = false;
                        };

                        startUnload = mkOption {
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
        };});
      };
    };
  };

  config = mkIf (cfg.enable) {
    boot = {
      initrd.kernelModules = [
        "vfio"
        "vfio_iommu_type1"
        "vfio_pci"
      ];

      extraModprobeConfig = let
        baseConfig = ''
          options vfio_iommu_type1 allow_unsafe_interrupts=1
          options kvm ignore_msrs=1
        '';


        vfioPciOptions = let
          join = ",";
          vendors = concatJoin join cfg.machines (vm:
            optionalConcatJoin {
              inherit join;
              condition = vm.passthrough.enable;
              array = vm.passthrough.pcies; 
              return = (pcie: concatJoin join pcie.lines.functions
                (function: lib.optionalString
                  (function.blacklist.vfioPriority)
                  function.vendor
                )
              );
            }
          );
        in lib.optionalString ("${vendors}" != "") ''
          options vfio-pci ids=${vendors} disable_vga=1 x-no-kvm-intx=on
        '';

        driverBlacklistOptions = concatFor cfg.machines (vm:
          optionalConcatFor {
            condition = vm.passthrough.enable;
            array = vm.passthrough.pcies;
            return = (pcie: concatFor pcie.lines.functions (function:
              optionalConcatFor {
                condition = (function.blacklist.driver && ! pcie.disk);
                array = function.drivers;
                return = (driver: ''
                  options ${driver} modeset=0
                  blacklist ${driver}
                '');
              }));
          });

        pciBlacklistOptions = concatFor cfg.machines (vm:
          optionalConcatFor {
            condition = vm.passthrough.enable;
            array = vm.passthrough.pcies;
            return = (pcie: concatFor pcie.lines.functions (function:
              optionalConcatFor {
                condition = (function.blacklist.vfioPriority && ! pcie.disk);
                array = function.drivers;
                return = (driver: ''
                  softdep ${driver} pre: vfio-pci
                '');
              }));
          });

      in lib.concatStrings ([
        baseConfig
        driverBlacklistOptions
        pciBlacklistOptions
        vfioPciOptions
      ]);

      kernelParams = [
        "intel_iommu=on"
        "amd_iommu=on"
        "iommu=pt"
        "kvm_amd.npt=1"
        "kvm_amd.avic=1"
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
      (writeShellApplication {
        name = "macos-dl";
        text = ''
          cd /var/lib/libvirt/images/;

          sudo ${pkgs.wget}/bin/wget \
            -O fetch-macos.py \
            https://raw.githubusercontent.com/kholia/OSX-KVM/master/fetch-macOS-v2.py
          sudo ${pkgs.python311}/bin/python3 fetch-macos.py;
          sudo rm -rf BaseSystem.img
          sudo ${pkgs.dmg2img}/bin/dmg2img -i BaseSystem.dmg BaseSystem.img;
          sudo rm -rf BaseSystem.dmg fetch-macos.py;

          sudo rm -rf OpenCore.qcow2
          sudo ${pkgs.wget}/bin/wget \
            -O OpenCore.qcow2 \
            https://github.com/kholia/OSX-KVM/raw/master/OpenCore/OpenCore.qcow2

          cd ..
          sudo mkdir -p firmware/macos
          cd firmware/macos

          sudo rm -rf OVMF_VARS.fd
          sudo ${pkgs.wget}/bin/wget \
            -O OVMF_VARS.fd \
            https://github.com/kholia/OSX-KVM/raw/master/OVMF_VARS-1920x1080.fd

          sudo rm -rf OVMF_CODE.fd
          sudo ${pkgs.wget}/bin/wget \
            -O OVMF_CODE.fd \
            https://github.com/kholia/OSX-KVM/raw/master/OVMF_CODE.fd
        '';
      })
    ];

    systemd.services.libvirtd.preStart = 
      lib.concatStrings (lib.forEach cfg.machines
    (vm:
      let
        uuidgen = vmName:
          exec "uuid-for-${vmName}" [ pkgs.libuuid ] ''
            uuidgen > $out
          '';

        ifElse = condition: resultIf: resultElse: (
          if condition
          then resultIf
          else resultElse
        );

        bindingPcie = let
          unbindPciesSetter = pcie: function: ''
            echo "${pcie}" > "/sys/bus/pci/devices/0000:${pcie}/driver/unbind" || true
            echo "${pcie}" > /sys/bus/pci/drivers/vfio-pci/new_id || true
          '';

          bindPciesSetter = pcie: function: ''
            echo "${function.vendor}" > "/sys/bus/pci/drivers/vfio-pci/remove_id" || true
            echo 1 > "/sys/bus/pci/devices/0000:${pcie}/remove" || true
          '';

          blacklistCondition = blacklist: pcie: lib.optionalString (
            ! blacklist.driver
            && blacklist.startUnload
            && ! blacklist.vfioPriority
          );

          bindingCondition = blacklist: pcie: lib.optionalString (
            ! blacklist.driver
            && ! blacklist.vfioPriority
            && ! blacklist.startUnload
          );

          finalString = condition: binding: optionalConcatFor {
            condition = vm.passthrough.enable;
            array = vm.passthrough.pcies;
            return = (pcie: concatFor pcie.lines.functions (function: let
              pcieId = "${pcie.lines.bus}:${pcie.lines.slot}.${function.function}";
            in 
              (condition function.blacklist pcie) (binding pcieId function)
            ));
          };

        in {
          bind = (finalString bindingCondition bindPciesSetter);
          unbind = (finalString bindingCondition unbindPciesSetter);
          startUnload = (finalString blacklistCondition unbindPciesSetter);
        };

        restartDmFormated = (lib.optionalString (
          vm.passthrough.enable
          && vm.passthrough.restartDm
        )
          "systemctl restart display-manager.service");

        uuid = ifElse (vm.uuid == "")
          (uuidgen vm.name)
          vm.uuid;

        lookingGlass = lib.optionalString (vm.lookingGlass) ''
          <shmem name='looking-glass'>
            <model type='ivshmem-plain'/>
            <size unit='M'>128</size>
            <address
              type='pci'
              domain='0x0000'
              bus='0x10'
              slot='0x01'
              function='0x0'
            />
          </shmem>
        '';

        lookingGlassFixPerm = lib.optionalString (vm.lookingGlass) ''
          chown ${cfg.username}:libvirtd /dev/shm/looking-glass
        '';

        uuidSetup = ifElse (vm.uuidSetup == "")
          (uuidgen "${vm.name}Setup")
          vm.uuidSetup;

        isVga = pcie: let
          result = exec "vga-check-${pcie}" [ pkgs.pciutils ] ''
            lspci -nns ${pcie} | grep VGA > $out || true
          '';
        in ifElse (result == "")
          false
          true;

        pciesXml = optionalConcatFor {
          condition = vm.passthrough.enable;
          array = vm.passthrough.pcies;
          return = (pcie: optionalConcatFor {
            condition = ! pcie.disk;
            array = pcie.lines.functions;
            return = (function: let
              pcieId =
                "${pcie.lines.bus}:${pcie.lines.slot}.${function.function}";
              rom = lib.optionalString (function.fix.rom && (isVga pcieId)) ''
                <rom bar="on" file="/var/lib/libvirt/roms/pcie-${pcieId}.rom"/>
              '';
            in ''
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
                    function='0x${function.function}'
                  />
                </source>
                ${rom}
                <address
                  type='pci'
                  domain='0x0000'
                  bus='0x${pcie.lines.vmBus}'
                  slot='0x${pcie.lines.slot}'
                  function='0x${function.function}'
                />
                <!-- multifunction='on' -->
              </hostdev>
            '');
          });
        };

        generateRoms = optionalConcatFor {
          condition = vm.passthrough.enable;
          array = vm.passthrough.pcies;
          return = (pcie: optionalConcatFor {
            condition = ! pcie.disk;
            array = pcie.lines.functions;
            return = (function: lib.optionalString (function.fix.rom) (let
              pcieId = "${pcie.lines.bus}:${pcie.lines.slot}.${function.function}";
            in lib.optionalString (isVga pcieId) ''
              if [ ! -f "/var/lib/libvirt/roms/pcie-${pcieId}.rom" ]; then
                PATH_TO_ROM=$(find /sys/devices/pci0000:00/ \
                  | grep ${pcieId} \
                  | grep rom)

                echo 1 > "$PATH_TO_ROM"
                cat "$PATH_TO_ROM" > /var/lib/libvirt/roms/pcie-${pcieId}.rom
                echo 0 > "$PATH_TO_ROM"
              fi
            ''));
          });
        };

        pciesDiskXml = optionalConcatFor {
          condition = vm.passthrough.enable;
          array = vm.passthrough.pcies;
          return = (pcie: optionalConcatFor {
            condition = pcie.disk;
            array = pcie.lines.functions;
            return = (function: ''
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
                    function='0x${function.function}'
                  />
                </source>
                <boot order="1"/>
                <address
                  type='pci'
                  domain='0x0000'
                  bus='0x${pcie.lines.vmBus}'
                  slot='0x${pcie.lines.slot}'
                  function='0x${function.function}'
                />
                <!-- multifunction='on' -->
              </hostdev>
            '');
          });
        };

        videoVirtio = (ifElse (vm.passthrough.enable)
          ''
            <model type='none'/>
          ''
          ''
            <model
              type="qxl"
              ram="65536"
              vram="65536"
              vgamem="16384"
              heads="1"
              primary="yes"
            />
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
          (ifElse (vm.os == "macos")
          ''
            <qemu:override>
              <qemu:device alias="sata0-0-0">
                <qemu:frontend>
                  <qemu:property name="rotation_rate" type="unsigned" value="1"/>
                </qemu:frontend>
              </qemu:device>
              <qemu:device alias="sata0-0-1">
                <qemu:frontend>
                  <qemu:property name="rotation_rate" type="unsigned" value="1"/>
                </qemu:frontend>
              </qemu:device>
              <qemu:device alias="sata0-0-2">
                <qemu:frontend>
                  <qemu:property name="rotation_rate" type="unsigned" value="1"/>
                </qemu:frontend>
              </qemu:device>
            </qemu:override>
          ''
          ''
            <qemu:override>
              <qemu:device alias="scsi0-0-0-0">
                <qemu:frontend>
                  <qemu:property name="rotation_rate" type="unsigned" value="1"/>
                </qemu:frontend>
              </qemu:device>
            </qemu:override>
          ''));

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

        disk = lib.optionalString (vm.hardware.disk.enable) ''
          <disk type='file' device='disk'>
            <driver name='qemu' type='qcow2' cache='directsync' discard='unmap'/>
            <source file='${vm.hardware.disk.path}/${vm.name}.qcow2'/>
            <target dev='sda' bus='scsi'/>
            <boot order='1'/>
            <address type='drive' controller='0' bus='0' target='0' unit='0'/>
          </disk>
        '';

        generateDisk = lib.optionalString vm.hardware.disk.enable ''
          if [ ! -f "${vm.hardware.disk.path}/${vm.name}.qcow2" ]; then
	          mkdir -p "${vm.hardware.disk.path}"
            qemu-img create \
              -f qcow2 "${vm.hardware.disk.path}/${vm.name}.qcow2" \
              ${(toString vm.hardware.disk.size)}G
          fi
        '';

        qemuHook = (pkgs.writeScript "qemu-hook" (
          builtins.replaceStrings [
            "{{ unbindPcies }}"
            "{{ bindPcies }}"
            "{{ restartDm }}"
            "{{ lookingGlassFixPerm }}"
          ] [
            (bindingPcie.unbind)
            (bindingPcie.bind)
            restartDmFormated
            lookingGlassFixPerm
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
            "{{ uuid }}"
            "{{ lookingGlass }}"
            "{{ disk }}"
            "{{ pciesDiskXml }}"
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
            (uuid)
            lookingGlass
            disk
            pciesDiskXml
          ] (builtins.readFile (ifElse (vm.os == "macos")
            ./src/macOS.xml
            ./src/template.xml))
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
            "{{ uuid }}"
            "{{ disk }}"
            "{{ pciesDiskXml }}"
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
            (uuidSetup)
            disk
            pciesDiskXml
          ] (builtins.readFile (ifElse (vm.os == "macos")
            ./src/macOS-setup.xml
            ./src/template-setup.xml))
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
          ${bindingPcie.startUnload}

          mkdir -p /var/lib/libvirt/{hooks,qemu,storage,roms}
          chmod 755 /var/lib/libvirt/{hooks,qemu,storage,roms}

          ${generateRoms}
          ${generateDisk}

          # Copy hook files
          ln -sf ${qemuHook} /var/lib/libvirt/hooks/qemu.d/${vm.name}
          ln -sf ${pathISO} /var/lib/libvirt/storage/ISO-${vm.name}.xml
          ln -sf ${templateConfig} /var/lib/libvirt/qemu/${vm.name}.xml
          ln -sf ${templateSetupConfig} /var/lib/libvirt/qemu/${vm.name}-setup.xml
        ''
    ));
  };
}
