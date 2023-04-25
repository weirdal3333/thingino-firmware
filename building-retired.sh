#!/bin/bash
#
# OpenIPC.org (c)
#

#
# Constants
#

MAX_KERNEL_SIZE=0x200000              #    2MiB,  2097152
MAX_KERNEL_SIZE_ULTIMATE=0x300000     #    3MiB,  3145728
MAX_KERNEL_SIZE_EXPERIMENTAL=0x3E8480 # ~3.9MiB,  4097152
MAX_ROOTFS_SIZE=0x500000              #    5MiB,  5242880
MAX_ROOTFS_SIZE_ULTIMATE=0xA00000     #   10MiB, 10485760

#
# Functions
#

echo_c() {
  # 30 grey, 31 red, 32 green, 33 yellow, 34 blue, 35 magenta, 36 cyan,37 white
  echo -e "\e[1;$1m$2\e[0m"
}

create_version() {
  local _d=$(date +"%y.%m.%d")
  OPENIPC_VER=$(echo OpenIPC v${_d:0:1}.${_d:1})
}

check_or_set_lock() {
  if [ -f "$LOCK_FILE" ] && ps -ax | grep "^\s*\b$(cat "$LOCK_FILE")\b" >/dev/null; then
    echo_c 31 "Another instance is running with PID $(cat "$LOCK_FILE")."
    exit 1
  fi

  echo_c 32 "Starting OpenIPC builder."
  echo_c 33 "Locking process with a lock file ${LOCK_FILE}"
  echo $$ >$LOCK_FILE
}

build_list_of_projects() {
  FUNCS=()
  AVAILABLE_PROJECTS=$(find br-ext-chip-*/configs/* -name "*_defconfig")
  local p
  for p in $AVAILABLE_PROJECTS; do
    p=${p##*/}; p=${p//_defconfig/}
    FUNCS+=($p)
  done
}

select_project() {
  if [ $# -eq 0 ]; then
    if [ -n "$(command -v fzf)" ]; then
      local entries=$(echo $AVAILABLE_PROJECTS | sed "s/ /\n/g" | fzf)
      [ -z "$entries" ] && echo_c 31 "Cancelled." && drop_lock_and_exit
      BOARD=$(echo $entries | cut -d / -f 3 | awk -F_ '{printf "%s_%s", $1, $2}')
    elif [ -n "$(command -v whiptail)" ]; then
      local cmd="whiptail --title \"Available projects\" --menu \"Please select a project from the list:\" --notags 20 76 12"
      local entry
      for entry in $AVAILABLE_PROJECTS; do
        local project=${entry##*/}; project=${project//_defconfig/}
        local vendor=${entry%%/*}; vendor=${vendor##*-}
        local flavor=${project##*_}
        local chip=${project%%_*}
        cmd="${cmd} \"${project}\" \"${vendor^} ${chip^^} ${flavor}\""
      done
      BOARD=$(eval "${cmd} 3>&1 1>&2 2>&3")
      [ $? != 0 ] && echo_c 31 "Cancelled." && drop_lock_and_exit
    else
      echo -ne "Usage: $0 <variant>\nVariants:"
      local i
      for i in "${FUNCS[@]}"; do echo -n " ${i}"; done
      echo
      drop_lock_and_exit
    fi
  else
    BOARD=$1
  fi
}

drop_lock_and_exit() {
  [ -f "$LOCK_FILE" ] && rm $LOCK_FILE
  exit 0
}

log_and_run() {
  local command=$1
  echo_c 35 "$command"
  $command
}

clone() {
  sudo apt-get update -y
  sudo apt-get install -y automake make wget cpio file autotools-dev bc build-essential curl fzf git libtool rsync unzip
  git clone --depth=1 https://github.com/OpenIPC/firmware.git
}

fresh() {
  if [ -d "$SRC_CACHE_DIR" ]; then
    echo_c 36 "Found cache directory."
  else
    echo_c 31 "Cache directory not found."
    echo_c 34 "Creating cache directory ..."
    log_and_run "mkdir -p ${SRC_CACHE_DIR}"
    echo_c 34 "Done.\n"
  fi

  mkdir -p ${SRC_DIR}
  BR_DIR="${SRC_DIR}/buildroot-${BR_VER}"
  if [ -d "${BR_DIR}" ]; then
    echo_c 36 "Found existing Buildroot directory."
  else
    echo_c 31 "Buildroot sources not found."
    BR_TMP=$(mktemp)
    echo_c 34 "Downloading Buildroot sources to cache directory ..."
    log_and_run "curl --continue-at - --output ${BR_TMP} https://buildroot.org/downloads/buildroot-${BR_VER}.tar.gz"
    log_and_run "tar -C ${SRC_DIR} -xf ${BR_TMP}"
    log_and_run "rm ${BR_TMP}"
    echo_c 34 "Done.\n"
  fi

#  if [ -z "$BR2_DL_DIR" ]; then
#    if [ -d "$SRC_CACHE_DIR" ]; then
#      echo_c 36 "Found cache directory."
#    else
#      echo_c 31 "Cache directory not found."
#      echo_c 34 "Creating cache directory ..."
#      log_and_run "mkdir -p ${SRC_CACHE_DIR}"
#      echo_c 34 "Done.\n"
#    fi
#
#    if [ -d "buildroot-${BR_VER}/dl" ]; then
#      echo_c 36 "Found existing Buildroot downloads directory."
#      echo_c 34 "Copying Buildroot downloads to cache directory ..."
#      log_and_run "cp -rvf buildroot-${BR_VER}/dl/* ${SRC_CACHE_DIR}"
#      echo_c 34 "Done.\n"
#    fi
#
#    echo_c 34 "Cleaning source directory."
#    echo_c 35 "make distclean"
#    make distclean
#    echo_c 34 "Done.\n"
#
#    echo_c 34 "Copying cached source files back to Buildroot ..."
#    log_and_run "mkdir -p buildroot-${BR_VER}/dl/"
#    log_and_run "cp -rvf ${SRC_CACHE_DIR}/* buildroot-${BR_VER}/dl/"
#    echo_c 34 "Done.\n"
#  else
#    make clean
#  fi

  # prevent to double download buildroot
  # make prepare

  if [ -d "$OUT_DIR" ]; then
    cd $OUT_DIR
    make clean
    cd ..
  else
    echo_c 33 "Making ${OUT_DIR} directory."
    mkdir -p $OUT_DIR
  fi

  echo_c 33 "Start building OpenIPC Firmware ${OPENIPC_VER} for ${BOARD}."
  echo "The start-stop times" >/tmp/openipc_buildtime.txt
  date >>/tmp/openipc_buildtime.txt
}

should_fit() {
  local filename=$1
  local maxsize=$2
  local filesize=$(stat --printf="%s" ${OUT_DIR}/images/${filename})
  if [[ $filesize -gt $maxsize ]]; then
    export TG_NOTIFY="Warning: $filename is too large: $filesize vs $maxsize"
    echo_c 31 "Warning: $filename is too large: $filesize vs $maxsize"
    exit 1
  fi
}

rename() {
  if [ "ultimate" = "$FW_FLAVOR" ] || [ "fpv" = "$FW_FLAVOR" ]; then
    should_fit uImage $MAX_KERNEL_SIZE_ULTIMATE
    should_fit rootfs.squashfs $MAX_ROOTFS_SIZE_ULTIMATE
  else
    should_fit uImage $MAX_KERNEL_SIZE
    should_fit rootfs.squashfs $MAX_ROOTFS_SIZE
  fi
  mv -v ${OUT_DIR}/images/uImage ${OUT_DIR}/images/uImage.${SOC}
  mv -v ${OUT_DIR}/images/rootfs.squashfs ${OUT_DIR}/images/rootfs.squashfs.${SOC}
  mv -v ${OUT_DIR}/images/rootfs.cpio ${OUT_DIR}/images/rootfs.${SOC}.cpio
  mv -v ${OUT_DIR}/images/rootfs.tar ${OUT_DIR}/images/rootfs.${SOC}.tar
  date >>/tmp/openipc_buildtime.txt
  echo_c 31 "\n\n$(cat /tmp/openipc_buildtime.txt)\n\n"
}

rename_initramfs() {
  should_fit uImage $MAX_KERNEL_SIZE_EXPERIMENTAL
  mv -v ${OUT_DIR}/images/uImage ${OUT_DIR}/images/uImage.initramfs.${SOC}
  mv -v ${OUT_DIR}/images/rootfs.cpio ${OUT_DIR}/images/rootfs.${SOC}.cpio
  mv -v ${OUT_DIR}/images/rootfs.tar ${OUT_DIR}/images/rootfs.${SOC}.tar
  date >>/tmp/openipc_buildtime.txt
  echo_c 31 "\n\n$(cat /tmp/openipc_buildtime.txt)\n\n"
}

autoup_rootfs() {
  echo_c 34 "\nDownloading u-boot created by OpenIPC"
  curl --location --output ${OUT_DIR}/images/u-boot-${SOC}-universal.bin \
    https://github.com/OpenIPC/firmware/releases/download/latest/u-boot-${SOC}-universal.bin

  echo_c 34 "\nMaking autoupdate u-boot image"
  ${OUT_DIR}/host/bin/mkimage -A arm -O linux -T firmware -n "$OPENIPC_VER" \
    -a 0x0 -e 0x50000 -d ${OUT_DIR}/images/u-boot-${SOC}-universal.bin \
    ${OUT_DIR}/images/autoupdate-uboot.img

  echo_c 34 "\nMaking autoupdate kernel image"
  ${OUT_DIR}/host/bin/mkimage -A arm -O linux -T kernel -C none -n "$OPENIPC_VER" \
    -a 0x50000 -e 0x250000 -d ${OUT_DIR}/images/uImage.${SOC} \
    ${OUT_DIR}/images/autoupdate-kernel.img

  echo_c 34 "\nMaking autoupdate rootfs image"
  ${OUT_DIR}/host/bin/mkimage -A arm -O linux -T filesystem -n "$OPENIPC_VER" \
    -a 0x250000 -e 0x750000 -d ${OUT_DIR}/images/rootfs.squashfs.${SOC} \
    ${OUT_DIR}/images/autoupdate-rootfs.img
}

copy_function() {
  test -n "$(declare -f "$1")" || return
  eval "${_/$1/$2}"
}

uni_build() {
  [ -z "$BOARD" ] && BOARD=$FUNCNAME

  SOC=$(echo $BOARD | cut -d '_' -f 1)

  # set -e
  # if [ "$(echo $BOARD | cut -sd '_' -f 2)" == "" ]; then
  #   BOARD="${BOARD}_lite"
  # fi

  if [ "$BOARD" == "hi3518ev200_lite" ]; then
    NEED_AUTOUP=1
  fi

  echo_c 33 "\n  SoC: $SOC\nBoard: $BOARD\n"

  if [ "all" = "${COMMAND}" ]; then
    fresh
  fi

  log_and_run "make BOARD=${BOARD} ${COMMAND}"

  if [ "all" == "${COMMAND}" ]; then
    if [ "ssc335_initramfs" == "$BOARD" ]; then
      rename_initramfs
    else
      rename
    fi

    if [ ! -z "$NEED_AUTOUP" ]; then
      autoup_rootfs
    fi
  fi
}

#######

create_version
build_list_of_projects

if [ -n "$1" ]; then
  BOARD=$1
else
  select_project
fi

if [ -z "$BOARD" ]; then
  echo_c 31 "Nothing selected."
  drop_lock_and_exit
fi

SRC_DIR="${HOME}/local/src"
SRC_CACHE_DIR="/tmp/buildroot_dl"

BR_VER=$(make BOARD=${BOARD} buildroot-version)
FW_FLAVOR=$(make BOARD=${BOARD} firmware-flavor)
OUT_DIR="../openipc-output/${BOARD}-br${BR_VER}"
OUT_DIR=$(realpath $OUT_DIR)
LOCK_FILE="/var/lock/openipc-${BOARD}-br${BR_VER}.lock"

check_or_set_lock

COMMAND=$2
[ -z "$COMMAND" ] && COMMAND=all

for i in "${FUNCS[@]}"; do
  copy_function uni_build $i
done

echo_c 37 "Building OpenIPC Firmware for ${BOARD} using Buildroot ${BR_VER}"

export SRC_DIR=$SRC_DIR
export BR_DIR=$BR_DIR
export OUT_DIR=$OUT_DIR

uni_build $BOARD $COMMAND

drop_lock_and_exit