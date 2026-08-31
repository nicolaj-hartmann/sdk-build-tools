#!/bin/bash
# -*- mode: sh;flycheck-sh-bash-args: ("-O" "extglob"); -*-
#
# SDK build engine creation script
#
# Copyright (C) 2014-2023 Jolla Oy
# Copyright (C) 2019-2020 Open Mobile Platform LLC.
# All rights reserved.
#
# You may use this file under the terms of BSD license as follows:
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#   * Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#   * Neither the name of the Jolla Ltd nor the
#     names of its contributors may be used to endorse or promote products
#     derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

. $(dirname $0)/defaults.sh
. $(dirname $0)/utils.sh

shopt -s extglob

OPT_UPLOAD_HOST=$DEF_UPLOAD_HOST
OPT_UPLOAD_USER=$DEF_UPLOAD_USER
OPT_UPLOAD_PATH=$DEF_UPLOAD_PATH

# ultra compression by default
OPT_COMPRESSION=9
OPT_RELEASE="latest"
OPT_TOOLING=
# Keep macOS bash 3.2 compatibility: no associative arrays, no ${var^^}
OPT_TARGET_ARCHES=()
OPT_TARGET_FILES=()
OPT_VM="MerSDK.build"
OPT_VDI=
OPT_TARGET_BASENAME=${DEF_TARGET_BASENAME}
OPT_VM_MEMORY=1024
OPT_QEMU_ARGS=

# some static settings for the VM
SSH_PORT=2222
HTTP_PORT=8080

# wrap it all up into these files
PACKAGE_NAME=buildengine-vbox.7z
DOCKER_PACKAGE_NAME=buildengine-docker.7z

fatal() {
    echo "FAIL: $@"
    exit 1
}

# silent 7z a bit
7z() {
    stdbuf -o0 7z "$@" |gawk '/^Compressing / { printf "Compressing...\r"; next } { print $0 }'
    return ${PIPESTATUS[0]}
}

# ---------------------------------------------------------------------
# VM backends: VirtualBox (x86 hosts) and QEMU (native aarch64 guests on
# Apple Silicon, using the same hypervisor acceleration as the emulator)

vboxmanage_wrapper() {
    echo "VBoxManage $@"
    VBoxManage "$@"
    [[ $? -ne 0 ]] && fatal "VBoxManage failed"
}

qemu_wrapper() {
    echo "qemu-system-aarch64 $@"
    qemu-system-aarch64 "$@"
    [[ $? -ne 0 ]] && fatal "qemu-system-aarch64 failed"
}

qemu_img_wrapper() {
    echo "qemu-img $@"
    qemu-img "$@"
    [[ $? -ne 0 ]] && fatal "qemu-img failed"
}

qemu_find_efi() {
    # edk2 aarch64 firmware shipped with homebrew/system qemu
    local candidates="/opt/homebrew/share/qemu/edk2-aarch64-code.fd \
                      /usr/local/share/qemu/edk2-aarch64-code.fd \
                      /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
                      /usr/share/edk2/aarch64/QEMU_EFI.fd"
    local fw
    for fw in $candidates; do
        [[ -f $fw ]] && { echo "$fw"; return 0; }
    done
    return 1
}

# QEMU process management (pidfile lives in the VM basefolder, see initPaths)
qemu_vm_running() {
    [[ -f $VM_BASEFOLDER/qemu.pid ]] && kill -0 $(cat $VM_BASEFOLDER/qemu.pid) 2>/dev/null
}

qemu_stop_vm() {
    if qemu_vm_running; then
        echo "Powering off QEMU VM (pid $(cat $VM_BASEFOLDER/qemu.pid))"
        kill $(cat $VM_BASEFOLDER/qemu.pid) 2>/dev/null
    fi
    rm -f $VM_BASEFOLDER/qemu.pid
}

# Run a command in the engine over ssh. Fails fast when the engine is not
# reachable instead of hanging forever.
engine_ssh() {
    ssh -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -o ConnectionAttempts=2 \
        -p $SSH_PORT \
        -i $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine/mersdk \
        mersdk@localhost "$@"
}

unregisterVm() {
    if [[ $OPT_BACKEND == "qemu" ]]; then
        echo "Stopping QEMU VM $OPT_VM"
        qemu_stop_vm
        return
    fi
    echo "Unregistering $OPT_VM"
    # make sure the VM is not running
    VBoxManage controlvm "$OPT_VM" poweroff 2>/dev/null
    VBoxManage unregistervm "$OPT_VM" --delete 2>/dev/null
}

prepareQemuDisk() {
    # Accept the same inputs as the VirtualBox flow: a raw/VDI file gets
    # converted to qcow2 once; qcow2 images are used as-is.
    local src=$OPT_VDI
    local dest=$VM_BASEFOLDER/mer.qcow2
    if [[ $dest -ef $src ]]; then
        OPT_QEMU_DISK=$src
        return
    fi
    mkdir -p $VM_BASEFOLDER
    echo "Converting $src => $dest"
    qemu_img_wrapper convert -O qcow2 "$src" "$dest"
    OPT_QEMU_DISK=$dest
}

createVM() {
    if [[ $OPT_BACKEND == "qemu" ]]; then
        prepareQemuDisk
        return
    fi
    vboxmanage_wrapper createvm --basefolder=$VM_BASEFOLDER --name "$OPT_VM" --ostype Linux26 --register
    vboxmanage_wrapper modifyvm "$OPT_VM" --memory $OPT_VM_MEMORY --vram 128 --accelerate3d off
    vboxmanage_wrapper storagectl "$OPT_VM" --name "SATA" --add sata --controller IntelAHCI $SATACOMMAND 1
    vboxmanage_wrapper storageattach "$OPT_VM" --storagectl SATA --port 0 --type hdd --mtype normal --medium $OPT_VDI
    vboxmanage_wrapper modifyvm "$OPT_VM" --nic1 nat --nictype1 virtio
    vboxmanage_wrapper modifyvm "$OPT_VM" --nic2 intnet --intnet2 sailfishsdk --nictype2 virtio --macaddress2 08005A11F155
    vboxmanage_wrapper modifyvm "$OPT_VM" --bioslogodisplaytime 1
    vboxmanage_wrapper modifyvm "$OPT_VM" --natpf1 "guestssh,tcp,127.0.0.1,${SSH_PORT},,22"
    vboxmanage_wrapper modifyvm "$OPT_VM" --natpf1 "guestwww,tcp,127.0.0.1,${HTTP_PORT},,9292"
    vboxmanage_wrapper modifyvm "$OPT_VM" --natdnshostresolver1 on
}

createShares() {
    # put 'ssh' and 'vmshare' into $SSHCONFIG_PATH
    mkdir -p $SSHCONFIG_PATH/ssh/mersdk
    if [[ $OPT_BACKEND != "qemu" ]]; then
        vboxmanage_wrapper sharedfolder add "$OPT_VM" --name ssh --hostpath $SSHCONFIG_PATH/ssh
    fi

    mkdir -p $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine
    pushd $SSHCONFIG_PATH/vmshare/ssh/private_keys/engine
    ssh-keygen -t rsa -N "" -f mersdk
    cp mersdk.pub $SSHCONFIG_PATH/ssh/mersdk/authorized_keys
    popd

    # required for the MerSDK network config
    cat <<EOF > $SSHCONFIG_PATH/vmshare/devices.xml
<?xml version="1.0" encoding="UTF-8"?>
<devices>
    <engine name="MerSDK" type="vbox">
        <subnet>10.220.220</subnet>
    </engine>
</devices>
EOF
    if [[ $OPT_BACKEND != "qemu" ]]; then
        vboxmanage_wrapper sharedfolder add "$OPT_VM" --name config --hostpath $SSHCONFIG_PATH/vmshare
    fi

    # and then 'targets' and 'home' for $INSTALL_PATH
    mkdir -p $INSTALL_PATH/targets
    if [[ $OPT_BACKEND == "qemu" ]]; then
        # Shared via virtio-9p with tags matching the VBox share names,
        # mounted to the expected in-engine paths after first boot (see
        # mountSharesQemu)
        return
    fi
    vboxmanage_wrapper sharedfolder add "$OPT_VM" --name targets --hostpath $INSTALL_PATH/targets
    vboxmanage_wrapper sharedfolder add "$OPT_VM" --name home --hostpath $INSTALL_PATH
}

mountSharesQemu() {
    # Mount the 9p shares to the paths where the engine integration expects
    # the VirtualBox shared folders. Idempotent.
    engine_ssh '
            set -e
            for pair in ssh:/host_ssh config:/host_config targets:/host_targets home:/host_home; do
                tag=${pair%%:*}
                mnt=${pair#*:}
                sudo mkdir -p "$mnt"
                grep -q " $mnt 9p" /proc/mounts || \
                    sudo mount -t 9p -o trans=virtio,version=9p2000.L "$tag" "$mnt"
            done
        '
}

startVM() {
    if [[ $OPT_BACKEND == "qemu" ]]; then
        local -a qemu_args=(
            -M virt -cpu host -accel hvf -smp $(nproc) -m $OPT_VM_MEMORY
            -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${HTTP_PORT}-:9292
            -fsdev local,id=sf_ssh,path=$SSHCONFIG_PATH/ssh,security_model=mapped-xattr
            -fsdev local,id=sf_config,path=$SSHCONFIG_PATH/vmshare,security_model=mapped-xattr
            -fsdev local,id=sf_targets,path=$INSTALL_PATH/targets,security_model=mapped-xattr
            -fsdev local,id=sf_home,path=$INSTALL_PATH,security_model=mapped-xattr
            -device virtio-9p-pci,fsdev=sf_ssh,mount_tag=ssh
            -device virtio-9p-pci,fsdev=sf_config,mount_tag=config
            -device virtio-9p-pci,fsdev=sf_targets,mount_tag=targets
            -device virtio-9p-pci,fsdev=sf_home,mount_tag=home
            -drive file=$OPT_QEMU_DISK,if=virtio,format=qcow2
            -display none -serial file:$VM_BASEFOLDER/console.log
            -pidfile $VM_BASEFOLDER/qemu.pid -daemonize
        )
        if [[ -n $OPT_KERNEL ]]; then
            qemu_args+=(-kernel $OPT_KERNEL)
            [[ -n $OPT_INITRD ]] && qemu_args+=(-initrd $OPT_INITRD)
            [[ -n $OPT_APPEND ]] && qemu_args+=(-append "$OPT_APPEND")
        else
            local efi=
            efi=$(qemu_find_efi) || fatal "No aarch64 EFI firmware found (install qemu with edk2 bits or pass --kernel)"
            qemu_args+=(-bios $efi)
        fi

        # allow the caller to override/extend anything from above
        if [[ -n $OPT_QEMU_ARGS ]]; then
            # shellcheck disable=SC2206
            qemu_args+=($OPT_QEMU_ARGS)
        fi

        mkdir -p $VM_BASEFOLDER
        echo "qemu-system-aarch64 ${qemu_args[*]} (daemonizing)"
        # detach the daemon's stdio from this script so that callers piping
        # our output do not block forever
        qemu-system-aarch64 "${qemu_args[@]}" </dev/null >> $VM_BASEFOLDER/qemu.out 2>&1
        [[ $? -ne 0 ]] && fatal "qemu-system-aarch64 failed (see $VM_BASEFOLDER/qemu.out)"

        # wait a few seconds
        sleep 2
        return
    fi
    vboxmanage_wrapper startvm --type headless "$OPT_VM"

    # wait a few seconds
    sleep 2
}

installTooling() {
    local tooling=$1
    local file=$2

    echo "Installing tooling $tooling to $OPT_VM"

    if [[ ! -f $OPT_TOOLING ]]; then
        fatal "$OPT_TOOLING does not exist!"
    fi

    ln $OPT_TOOLING $INSTALL_PATH/

    echo "Creating tooling ..."
    engine_ssh "sdk-manage --mode installer --tooling --install $tooling file:///host_home/$file"
}

installTarget() {
    local tgt=$1
    local file=$2

    echo "Installing target $tgt to $OPT_VM"

    if [[ ! -f $file ]]; then
        fatal "$file does not exist!"
    fi

    ln $file $INSTALL_PATH/

    echo "Creating target ..."
    engine_ssh "sdk-manage --mode installer --target --install --jfdi $tgt file:///host_home/$file"
}

createTar() {
    echo "Mounting vdi ..."
    sudo modprobe nbd max_part=16
    sudo qemu-nbd -c /dev/nbd0 mersdk/mer.vdi
    sleep 1 
    if [[ ! -e /dev/nbd0p1 ]]; then
        fatal "/dev/nbd0p1 does not exist!"
    fi
    mkdir -p mer.d
    sudo mount /dev/nbd0p1 mer.d

    echo "Changing permissions of /srv/mer ..."
    sudo chmod -R a+rwX mer.d/srv/mer

    echo "Compressing filesystem ..."
    sudo tar -C mer.d --exclude './srv/mer/*' -cf mersdk/sailfish.tar --one-file-system --numeric-owner .
    sudo tar -C mer.d/srv/mer -cf mersdk/sailfish-tools.tar --numeric-owner .
    sudo umount mer.d
    sudo qemu-nbd -d /dev/nbd0

    sudo chown "$USER:$USER" -- mersdk/sailfish*.tar
}

checkVBox() {
    # check that VBox is 4.3 or newer - affects the sataport count.
    VBOX_TOCHECK="4.3"
    echo "Using VirtualBox v$VBOX_VERSION"
    if [[ $(bc <<< "$VBOX_VERSION >= $VBOX_TOCHECK") -eq 1 ]]; then
        SATACOMMAND="--portcount"
    else
        SATACOMMAND="--sataportcount"
    fi
}

initPaths() {
    # anything under this directory will end up in the package
    RELATIVE_INSTALL_PATH=mersdk
    INSTALL_PATH=$PWD/$RELATIVE_INSTALL_PATH
    rm -rf $INSTALL_PATH
    mkdir -p $INSTALL_PATH
    # anything under this directory will end up in the docker package
    DOCKER_PREFIX=$PWD/docker
    DOCKER_INSTALL_PATH=$DOCKER_PREFIX/$RELATIVE_INSTALL_PATH
    rm -rf $DOCKER_INSTALL_PATH
    mkdir -p $DOCKER_INSTALL_PATH
    # copy refresh script to an accessible path, this needs to be
    # removed later
    cp -a $BUILD_TOOLS_SRC/refresh-sdk-repos.sh $INSTALL_PATH
    cp -a $BUILD_TOOLS_SRC/hack-snapshots-cow.sh $INSTALL_PATH

    # this is not going to end up inside the package
    SSHCONFIG_PATH=$PWD/sshconfig
    rm -rf $SSHCONFIG_PATH
    mkdir -p $SSHCONFIG_PATH

    # this is not going to end up inside the package
    VM_BASEFOLDER=$PWD/basefolder
    rm -rf $VM_BASEFOLDER
    mkdir -p $VM_BASEFOLDER
}

checkIfVMexists() {
    if [[ -n $(VBoxManage list vms 2>&1 | grep $OPT_VM) ]]; then
        fatal "$OPT_VM already exists. Please unregister it from VirtualBox before proceeding."
    fi
}

checkForRequiredFiles() {
    if [[ ! -f $OPT_VDI ]]; then
        fatal "VDI file [$OPT_VDI] not found in the current directory."
    fi

    if [[ ! -f $OPT_TOOLING ]]; then
        fatal "Tooling file [$OPT_TOOLING] not found in the current directory."
    fi

    for target_filename in "${OPT_TARGET_FILES[@]}"; do
        if [ ! -e "$target_filename" ] ; then
            fatal "Target file [$target_filename] not found in the current directory."
        fi
    done
}

packVM() {
    echo "Creating 7z package ..."
    # Shut down the VM so it won't interfere (and make sure it's down). This
    # will probably fail because sdk-shutdown has already done its job, so
    # ignore any error output.
    if [[ $OPT_BACKEND == "qemu" ]]; then
        qemu_stop_vm
    else
        VBoxManage controlvm "$OPT_VM" poweroff 2>/dev/null
    fi

    # remove target archive files
    rm -f $INSTALL_PATH/$OPT_TOOLING
    for target_filename in "${OPT_TARGET_FILES[@]}"; do
        rm -f "$INSTALL_PATH/$target_filename"
    done

    # remove stuff that is not meant to end up in the package
    rm -f $INSTALL_PATH/.bash_history $INSTALL_PATH/refresh-sdk-repos.sh
    rm -f $INSTALL_PATH/hack-snapshots-cow.sh

    # copy the used disk image:
    if [[ $OPT_BACKEND == "qemu" ]]; then
        echo "Hard linking $OPT_QEMU_DISK => $INSTALL_PATH/mer.qcow2"
        ln $OPT_QEMU_DISK $INSTALL_PATH/mer.qcow2
    else
        echo "Hard linking $PWD/$OPT_VDI => $INSTALL_PATH/mer.vdi"
        ln $PWD/$OPT_VDI $INSTALL_PATH/mer.vdi
    fi

    mkdir -p vmshare
    cp $SSHCONFIG_PATH/vmshare/df.cache vmshare/

    if [[ ! $OPT_NO_COMPRESSION ]]; then
        # and 7z the mersdk with chosen compression
        7z a -mx=$OPT_COMPRESSION $PACKAGE_NAME $INSTALL_PATH/ vmshare/
    fi
}

packDocker() {
    echo "Creating Docker 7z package..."
     # move the docker tarball to docker directory
    mv $INSTALL_PATH/sailfish*.tar $DOCKER_INSTALL_PATH/

    if [[ ! $OPT_NO_COMPRESSION ]]; then
        local threads=$(nproc)
        (( threads > 1 )) && let threads-- # be nice
        xz -$OPT_COMPRESSION -T $threads $DOCKER_INSTALL_PATH/sailfish*.tar
    fi

    echo "copying $INSTALL_PATH/targets => $DOCKER_INSTALL_PATH/targets"
    cp -R $INSTALL_PATH/targets $DOCKER_INSTALL_PATH/targets

    cp $(dirname $0)/seccomp.json $DOCKER_INSTALL_PATH/

    if [[ ! $OPT_NO_COMPRESSION ]]; then
        # and 7z the mersdk with chosen compression
        pushd $DOCKER_PREFIX
        7z a -mx=$OPT_COMPRESSION $DOCKER_PACKAGE_NAME $RELATIVE_INSTALL_PATH/!(sailfish*.tar.xz)
        7z a -mx=0 $DOCKER_PACKAGE_NAME $RELATIVE_INSTALL_PATH/sailfish*.tar.xz
        popd
        mv $DOCKER_PREFIX/$DOCKER_PACKAGE_NAME .
    fi
}

checkForRunningVms() {
    local running=$(VBoxManage list runningvms 2>/dev/null)

    if [[ -n $running ]]; then
        echo -n "These virtual machines are running "

        if [[ -n $OPT_IGNORE_RUNNING ]]; then
            echo "[IGNORED]"
        else
            echo "- please stop them before continuing."
        fi

        echo $running

        [[ -n $OPT_IGNORE_RUNNING ]] || exit 1
    fi
}

usage() {
    cat <<EOF
Create $PACKAGE_NAME and optionally upload it to a server.

Usage:
   $(basename $0) -f <VDI> [OPTION]         setup and package the VM
   $(basename $0) unregister [-vm <NAME>]   unregister the VM

Options:
    -u   | --upload <DIR>       upload local build result to [$OPT_UPLOAD_HOST] as user [$OPT_UPLOAD_USER]
                                the uploaded build will be copied to [$OPT_UPLOAD_PATH/<DIR>]
                                the upload directory will be created if it is not there
    -uh  | --uhost <HOST>       override default upload host
    -up  | --upath <PATH>       override default upload path
    -uu  | --uuser <USER>       override default upload user
    -y   | --non-interactive    answer yes to all questions presented by the script
    -f   | --vdi-file <VDI>     use <VDI> file as the virtual disk image [required]
                                on the qemu backend .vdi files are converted to
                                qcow2, .qcow2 and raw images are used as-is
    -i   | --ignore-running     ignore running VMs
    -r   | --refresh            force a zypper refresh for MerSDK and sb2 targets
    -p   | --private            use private rpm repository in 10.21.0.20
    -td  | --test-domain        keep test domain after refreshing the repos
    -o   | --orig-release <REL> turn ssu release to this instead of latest after refreshing repos
    -rel | --release <REL>      release number to mention in tooling/target names
    -c   | --compression <0-9>  compression level of 7z [$OPT_COMPRESSION]
    -nc  | --no-compression     do not create the 7z
    -t   | --tooling <FILE>     tooling tarball <FILE>, must be in current directory
    --target-<ARCH> <FILE>      <ARCH> target rootstrap <FILE>, must be in current directory
    -un  | --unregister         unregister the created VM at the end of script run
    -hax | --horrible-hack      disable jolla-core.check systemCheck file
    -vm  | --vm-name <NAME>     create VM with <NAME> [$OPT_VM]
    --no-meta                   suppress creating meta data files with
                                'make-archive-meta.sh'
    --target-basename <NAME>    base name for tooling and targets,
                                must use alphanumeric characters only [$OPT_TARGET_BASENAME]
    --backend <BACKEND>         virtualization backend: vbox or qemu
                                [auto: qemu on arm64 macOS, vbox otherwise]
    --memory <MB>               guest memory in MB [$OPT_VM_MEMORY]
    --kernel <FILE>             (qemu) boot this kernel image directly
    --initrd <FILE>             (qemu) initrd for --kernel
    --append <STR>              (qemu) kernel command line for --kernel
    --qemu-args <ARGS>          (qemu) extra arguments passed to qemu-system-aarch64
    -h   | --help               this help

EOF

    # exit if any argument is given
    [[ -n "$1" ]] && exit 1
}

# BASIC EXECUTION STARTS HERE:

# handle commandline options
while [[ ${1:-} ]]; do
    case "$1" in
        -c | --compression ) shift
            OPT_COMPRESSION=$1; shift
            if [[ $OPT_COMPRESSION != [0123456789] ]]; then
                usage quit
            fi
            ;;
	-nc | --no-compression ) shift
	    OPT_NO_COMPRESSION=1
	    ;;
        -f | --vdi-file ) shift
            OPT_VDI=$1; shift
            ;;
        -t | --tooling ) shift
            # Enforce that the file resides under CWD for sharing with build engine
            OPT_TOOLING=$(basename $1); shift
            ;;
        --target-* )
            # Enforce that the file resides under CWD for sharing with build engine
            OPT_TARGET_ARCHES+=(${1#--target-})
            OPT_TARGET_FILES+=($(basename $2))
            shift 2
            ;;
        -td | --test-domain ) shift
            OPT_KEEP_TEST_DOMAIN="--test-domain"
            ;;
        -i | --ignore-running ) shift
            OPT_IGNORE_RUNNING=1
            ;;
        -hax | --horrible-hack ) shift
            OPT_HACKIT=1
            ;;
        -r | --refresh ) shift
            OPT_REFRESH=1
            ;;
	-p | --private ) shift
	    OPT_PRIVATE_REPO="-p"
	    ;;
	-o | --orig-release ) shift
	    OPT_ORIGINAL_RELEASE=$1; shift
	    [[ -z $OPT_ORIGINAL_RELEASE ]] && fatal "empty original release option given"
	    ;;
        -rel | --release ) shift
            OPT_RELEASE=$1; shift
            [[ -z $OPT_RELEASE ]] && fatal "empty release option given"
            ;;
        -u | --upload ) shift
            OPT_UPLOAD=1
            OPT_UL_DIR=$1; shift
            if [[ -z $OPT_UL_DIR ]]; then
                fatal "upload option requires a directory name"
            fi
            ;;
        -vm | --vm-name ) shift
            OPT_VM=$1; shift
            ;;
        -uh | --uhost ) shift;
            OPT_UPLOAD_HOST=$1; shift
            ;;
        -up | --upath ) shift;
            OPT_UPLOAD_PATH=$1; shift
            ;;
        -uu | --uuser ) shift;
            OPT_UPLOAD_USER=$1; shift
            ;;
        --no-meta ) shift
            OPT_NO_META=1
            ;;
        -h | --help ) shift
            usage quit
            ;;
        -y | --non-interactive ) shift
            OPT_YES=1
            ;;
        -un | --unregister ) shift
            OPT_UNREGISTER=1
            ;;
        unregister ) shift
            OPT_DO_UNREGISTER=1
            ;;
        --target-basename ) shift
            OPT_TARGET_BASENAME=$1; shift
            [[ -z $OPT_TARGET_BASENAME ]] && fatal "empty target-basename option given"
            ;;
        --backend ) shift
            OPT_BACKEND=$1; shift
            case $OPT_BACKEND in
                vbox|qemu) ;;
                *) fatal "unknown backend [$OPT_BACKEND], use vbox or qemu"
            esac
            ;;
        --memory ) shift
            OPT_VM_MEMORY=$1; shift
            ;;
        --kernel ) shift
            OPT_KERNEL=$1; shift
            ;;
        --initrd ) shift
            OPT_INITRD=$1; shift
            ;;
        --append ) shift
            OPT_APPEND=$1; shift
            ;;
        --qemu-args ) shift
            OPT_QEMU_ARGS=$1; shift
            ;;
        * )
            usage quit
            ;;
    esac
done

# resolve backend: explicit option wins, otherwise native aarch64 Macs
# use QEMU (the engine guest must match the host architecture), everything
# else uses VirtualBox
if [[ -z $OPT_BACKEND ]]; then
    if [[ $UNAME_SYSTEM == "Darwin" && $UNAME_ARCH == "arm64" ]]; then
        OPT_BACKEND=qemu
    else
        OPT_BACKEND=vbox
    fi
fi

# check that the virtualization backend is available
if [[ $OPT_BACKEND == "vbox" ]]; then
    VBOX_VERSION=$(VBoxManage --version 2>/dev/null | cut -f -2 -d '.')
    if [[ -z $VBOX_VERSION ]]; then
        fatal "VBoxManage not found."
    fi
else
    if ! command -v qemu-system-aarch64 >/dev/null; then
        fatal "qemu-system-aarch64 not found (brew install qemu)"
    fi
    if [[ $UNAME_SYSTEM != "Darwin" || $UNAME_ARCH != "arm64" ]]; then
        echo "WARNING: QEMU backend expects an aarch64 macOS host with native acceleration (hvf)"
    fi
fi

# handle the explicit unregister case here
if [[ -n $OPT_DO_UNREGISTER ]]; then
    unregisterVm
    exit $?
fi

if [[ -z $OPT_VDI ]]; then
    # Always require a given vdi file
    fatal "VDI file option is required (-f filename.vdi)"
fi

if [[ ${OPT_VDI: -4} == ".bz2" ]]; then
    echo "unpacking $OPT_VDI ..."
    bunzip2 -f -k $OPT_VDI
    OPT_VDI=${OPT_VDI%.bz2}
fi

# get our VDI's formatted filename
OPT_VDI=$(basename $OPT_VDI)

# user can decide to care or not about running vms
if [[ $OPT_BACKEND == "vbox" ]]; then
    checkForRunningVms
fi

# do we have everything..
checkForRequiredFiles

# clear our workarea
initPaths

# some preliminary checks
if [[ $OPT_BACKEND == "vbox" ]]; then
    checkVBox
    checkIfVMexists
fi

# all go, let's do it:
echo "Creating $OPT_VM, compression=$OPT_COMPRESSION"

{
    echo "Release:;$OPT_RELEASE"
    echo "MerSDK VDI:;$OPT_VDI"
    echo "Tooling:;$OPT_TOOLING"
    for i in ${!OPT_TARGET_ARCHES[*]} ; do
        echo "$(echo ${OPT_TARGET_ARCHES[$i]} | tr '[:lower:]' '[:upper:]') target:;${OPT_TARGET_FILES[$i]}"
    done
} |column -t -s ';' |sed 's/^/ /'

if [[ -n $OPT_REFRESH ]]; then
    echo " Force zypper refresh for repos"
    if [[ -n $OPT_PRIVATE_REPO ]]; then
	if [[ -n $OPT_KEEP_TEST_DOMAIN ]]; then
            echo " ... and keep test ssu domain after refresh"
	else
	    echo " ... after update set ssu release to [${OPT_ORIGINAL_RELEASE:-latest}]"
	fi
    fi
else
    echo " Do NOT refresh repos"
fi
if [[ $OPT_NO_COMPRESSION ]]; then
    echo " Do NOT compress the resulting VDI"
fi
if [[ -n $OPT_UPLOAD ]]; then
    echo " Upload build results as user [$OPT_UPLOAD_USER] to [$OPT_UPLOAD_HOST:$OPT_UPLOAD_PATH/$OPT_UL_DIR]"
else
    echo " Do NOT upload build results"
fi

if [[ -n $OPT_HACKIT ]]; then
    echo " ### DO HORRIBLE SYSTEMCHECK HACK!!! ###"
fi

# confirm
if [[ -z $OPT_YES ]]; then
    while true; do
        read -p "Do you want to continue? (y/n) " answer
        case $answer in
            [Yy]*)
                break ;;
            [Nn]*)
                echo "Ok, exiting"
                exit 0
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
fi

# record start time
BUILD_START=$(date +%s)

# set up machine in the backend
createVM
# define the shared directories
createShares
# start the VM
startVM

# on the QEMU backend the 9p shares must be mounted explicitly, the engine
# has no VirtualBox guest additions to do it
if [[ $OPT_BACKEND == "qemu" ]]; then
    mountSharesQemu
fi

# install tooling to the VM
installTooling "$OPT_TARGET_BASENAME-$OPT_RELEASE" "$OPT_TOOLING"

# install targets to the VM
TARGET_NAMES=()
for i in ${!OPT_TARGET_ARCHES[*]}; do
    installTarget "$OPT_TARGET_BASENAME-$OPT_RELEASE-${OPT_TARGET_ARCHES[$i]}" "${OPT_TARGET_FILES[$i]}"
    TARGET_NAMES+=("$OPT_TARGET_BASENAME-$OPT_RELEASE-${OPT_TARGET_ARCHES[$i]}")
done

if [[ -n $OPT_HACKIT ]]; then
    echo "### EMBARRASSING HACK! CLEANING jolla-core.check!!!"
    engine_ssh "cat /dev/null | sudo tee /etc/zypp/systemCheck.d/jolla-core.check"
fi

# Hack: ensure snapshots are CoW copies also with Docker
engine_ssh "sudo bash /host_home/hack-snapshots-cow.sh"

# refresh the zypper repositories
if [[ -n $OPT_REFRESH ]]; then
    engine_ssh "sudo bash /host_home/refresh-sdk-repos.sh -y ${OPT_PRIVATE_REPO:-} ${OPT_KEEP_TEST_DOMAIN:-} --release ${OPT_ORIGINAL_RELEASE:-latest}"
fi

# shut the VM down cleanly so that it has time to flush its disk
engine_ssh "sdk-shutdown"

echo "Giving VM 10 seconds to really shut down ..."
while [[ $(( waitc++ )) -lt 10 ]]; do

    if [[ $OPT_BACKEND == "qemu" ]]; then
        qemu_vm_running || break
    else
        [[ $(VBoxManage list runningvms | grep -c $OPT_VM) -eq 0 ]] && break
    fi

    echo "waiting ..."
    sleep 1

    [[ $waitc -ge 10 ]] && echo "WARNING: $OPT_VM did not shut down cleanly!"
done

# wrap it all up into 7z file for installer:
packVM

if [[ $OPT_BACKEND == "vbox" ]]; then
    # start the VM
    createTar

    packDocker
else
    echo "NOTE: Skipping Docker package (qemu-nbd based, requires a Linux build host)"
fi

results=($PACKAGE_NAME)

if [[ -z $OPT_NO_META ]]; then
    if [[ -f $INSTALL_PATH/mer.vdi ]]; then
        vdi_capacity=$(vdi_capacity <$INSTALL_PATH/mer.vdi)
        $BUILD_TOOLS_SRC/make-archive-meta.sh $PACKAGE_NAME "vdi_capacity=$vdi_capacity" \
            "targets=$(echo -n ${TARGET_NAMES[*]})"
    else
        $BUILD_TOOLS_SRC/make-archive-meta.sh $PACKAGE_NAME \
            "targets=$(echo -n ${TARGET_NAMES[*]})"
    fi
    results+=($PACKAGE_NAME.meta)
fi

if [[ -n "$OPT_UPLOAD" ]]; then
    echo "Uploading build results ..."

    # create upload dir
    ssh $OPT_UPLOAD_USER@$OPT_UPLOAD_HOST mkdir -p $OPT_UPLOAD_PATH/$OPT_UL_DIR/
    scp ${results[*]} $OPT_UPLOAD_USER@$OPT_UPLOAD_HOST:$OPT_UPLOAD_PATH/$OPT_UL_DIR/
fi

if [[ -n $OPT_UNREGISTER ]]; then
    unregisterVm
fi

# record end time
BUILD_END=$(date +%s)

echo "================================="
time=$(( BUILD_END - BUILD_START ))
hour=$(( $time / 3600 ))
mins=$(( $time / 60 - 60*$hour ))
secs=$(( $time - 3600*$hour - 60*$mins ))

echo Time used: $(printf "%02d:%02d:%02d" $hour $mins $secs)

# For Emacs:
# Local Variables:
# indent-tabs-mode:nil
# tab-width:8
# sh-basic-offset:4
# End:
# For VIM:
# vim:set softtabstop=4 shiftwidth=4 tabstop=8 expandtab:
