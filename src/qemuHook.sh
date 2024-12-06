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
      {{ lookingGlassFixPerm }}
    ;;

    "releasex")
      {{ bindPcies }}
      echo 1 > "/sys/bus/pci/rescan"
      {{ restartDm }}
    ;;
  esac
fi
