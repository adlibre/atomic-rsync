#!/usr/bin/env bash

# Atomic Rsync
# Remote Rsync with automatic LVM snapshot.
# Andrew Cutler 2012 Adlibre Pty Ltd
# v0.2.x

#
# Install via an SSH forced command. Add to authorized_keys:
# .... ~atomic/.ssh/authorized_keys
# command="/usr/bin/sudo /usr/local/bin/atomic.sh $SSH_ORIGINAL_COMMAND" ssh-dss AAAAB....
# ....
# If using a non root user, then sudo might be required. eg:
# .... /etc/sudoers
# atomic  ALL=NOPASSWD: /usr/bin/rsync, /usr/local/bin/atomic.sh
# ....
# NB Make sure requiretty is off
#

#
# Limitations: 
#  * Multiple src paths not yet supported in a single run
#  * Exclusions might not work de to ordering of commands. (should be possible to get to work but need to check they are rooted in the snapshot point not the fs root.)
#

# TODO: 
#  * Error handling / checking that we have enough snapshotspace

# DEFAULTS
SNAP_SIZE='1G'
SNAP_SUFFIX='_atomic_rsync'
TARGET_ROOT='/mnt/'
DEBUG=false
DEBUG_LOG="/tmp/atomic-rsync-$$.log"
# END DEFAULTS

# source local configuration first from local dir then try etc
if [ -f ./atomic.conf ]; then
    . ./atomic.conf
elif [ -f /etc/atomic.conf ]; then
    . /etc/atomic.conf
fi

#
# Functions
#

function mountsInPath() {
    # Return all potential ext(2,3,4) mounts in the path $1
    cat /proc/mounts | egrep ' ext(2|3|4)' | awk '{ print $2","$1 }' | grep ^${1} | sort
}

function getLVMDevice() {
    # $1 = '/home' returns /dev/vg_sys/lv_home
    ARG=`echo $1 | sed 's@/$@@g'` # remove trailing slash
    DEVICE=`grep " $ARG " /proc/mounts | awk '{print $1}' | xargs --no-run-if-empty lvdisplay -c 2> /dev/null | sed -e 's@:.*@@g;s@ @@g'`
    echo ${DEVICE}
    if ${DEBUG}; then
        echo "getLVMDevice: ${DEVICE}" >> $DEBUG_LOG
    fi
}

function isLVM() {
    # is device $1 LVM
    CMD=`getLVMDevice ${1}`
    if [ "$CMD" == "" ]; then
        # is not LVM
        exit 1;
    else
        # is LVM
        exit 0;
    fi
}

function atomicRsync() {
    # Mount all lvms in the backup path in a new root and point rsync root there
    
    for m in $(mountsInPath ${1}); do

        SRC_MOUNT=$(echo $m | sed -e 's@,@ @g' | awk '{ print $1 }')
        SRC_DEVICE=$(echo $m | sed -e 's@,@ @g' | awk '{ print $2 }')
        TARGET_MNT=${TARGET_ROOT}${SRC_MOUNT}
        
        if [ -d ${TARGET_MNT} ]; then
            mkdir -p ${TARGET_MNT}
            trap $(rmdir ${TARGET_MNT}) EXIT
        fi
    
        if isLVM $SRC_MOUNT; then
            # is lvm snapshot the device and mount in our root
            SRC_LV_DEVICE=${SRC_DEVICE}
            SNAP_LV_DEVICE=${SRC_LV_DEVICE}${SNAP_SUFFIX}
            SNAP_NAME=$(basename ${SRC_LV_DEVICE})${SNAP_SUFFIX}
            
            trap $(umount ${TARGET_MNT} && lvremove -f ${SNAP_LV_DEVICE} && rmdir ${TARGET_MNT}) EXIT # unmount automatically on function exit
            
            sync && \
            lvcreate -s ${SRC_LV_DEVICE} -n ${SNAP_NAME} -L ${SNAP_SIZE} 1> /dev/null
            mount -o ro ${SNAP_LV_DEVICE} ${TARGET_MNT}
        else
            # is not LVM, just perform a bind mount
            trap $(umount ${TARGET_MNT}) EXIT # No need to remove bind dir
            mount -o bind ${SRC_MOUNT} ${TARGET_MNT}
        fi
            
    done
    
    RSYNC_ARGS="`echo ${RSYNC_ARGS} | sed 's@[ ][^ ]*$@@'` ./" # replace last argument with relative path
    cd ${TARGET_ROOT} && \
    /usr/bin/rsync ${RSYNC_ARGS}
}

#
# Main code here
#

RSYNC_ARGS=`shift; echo "$@"`
RSYNC_PATH=`echo "${RSYNC_ARGS}" | sed 's/.* //'` # last argument

if ${DEBUG}; then
    echo "Started with args: $RSYNC_ARGS" >> $DEBUG_LOG
fi

atomicRsync $RSYNC_PATH