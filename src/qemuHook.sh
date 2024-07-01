#!/bin/sh
OBJECT="$1"
OPERATION="$2"

if [[ "${OBJECT}x" == "win11x" ]]; then
  case "${OPERATION}x"
    in "preparex")
      {{ unbindPcies }}
      {{ restartDm }}
    ;;

    "startedx")
      chown {{ username }}:libvirtd /dev/shm/looking-glass
    ;;

    "releasex")
      {{ bindPcies }}
      {{ restartDm }}
    ;;
  esac
fi
