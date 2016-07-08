#!/usr/bin/ksh
#
# This script will perform several activities related to Business Copy,
# like pairsplit, pairesync, LVM and filesystem operations, etc.
#
#
# $Revision: 1.31 $
# ----------------------------------------------------------------------------

# DEBUGGING
DEBUG=""    # use -d option to trigger debugging

# ------------------------------------------------------------------------------
# Paramters --------------------------------------------------------------------
# ------------------------------------------------------------------------------

typeset -x PRGNAME=${0##*/}
typeset -x PRGDIR=${0%/*}
typeset -x PID=$$
typeset -r platform=$(uname -s)		# Operating System name, e.g. Linux, HP-UX, SunOS
typeset -r lhost=$(uname -n)            # Local host name
typeset -r osVer=$(uname -r)            # OS Release
typeset model=$(uname -m)               # Model of the system
typeset ERRfile=/tmp/BC-exec-${PID}-ERRfile.txt  # contains the exit code (will be read at the end of the script)
typeset MVlog2DIR=/tmp/BC-exec-${PID}-move-logfile-to-dlog  # this file contains the user variable of -D option
typeset LOCKDIR=/tmp/BC-exec-LOCKDIR
typeset PIDFILE=${LOCKDIR}/BC-exec-PIDFILE

[[ $PRGDIR = /* ]] || {                                 # acquire an absolute path
    case $PRGDIR in
        . ) PRGDIR=$(pwd) ;;
        * ) PRGDIR=$(pwd)/$PRGDIR ;;
    esac
    }

typeset -x LANG="C"
typeset -x LC_ALL="C"

typeset -x CONFIGDIR=                   # usually /opr_<pkgname>/BC
typeset -x FAILBACK_CONFIGDIR=          # usually /var/tmp/BC/<pkgname> [when CONFIGDIR is not available, e.g pkg is down]
typeset -r STARTDATE=$(date +%Y%m%d-%H%M%S)
typeset -x mailusr=

# following set must be read from the configuration file
# /opr_<package-name>/BC/<package-name>.cfg
# or from /path/BC/configuration_file
typeset LAYOUT="1.0"                  # old style of configuration file (variable settings only)
typeset PVOL_INST=""
typeset SVOL_INST=""
typeset BC_TIMEOUT=""
set -A  VOL_GRP                       # array containing Volume Groups
set -A  DEV_GRP                       # array containing Device Groups (to do BCV stuff with VG)
typeset REMOVE_CLUSTER_MODE=""

# internal used variables
typeset  VOL_GRP_s # short Volume Group name without /dev/ and trailing /
typeset  VOL_GRP_l # long Volume Group name including /dev/ and trailing /
typeset  FORCE_MOUNT_PREFIX=""        # BCV MU#0 uses original mount points
typeset  SUSPEND_SYNC=""
typeset  SUSPEND_SYNC_FLAG=""         # to force a break at the resync workflow (maintenance flag)
                                      # default empty (do not interrupt the resync workflow)
typeset PurgeOlderThenDays=

# Settings according platform OS type:
case ${platform} in
    HP-UX)
	 typeset dlog=/var/adm/log                       # log directory
	 ;;
    Linux)
	 typeset dlog=/var/adm/log
	 ;;
    SunOS)
	 ;;
    *    )
	 ;;
esac

# ------------------------------------------------------------------------------
# Functions --------------------------------------------------------------------
# ------------------------------------------------------------------------------

function Usage 
{
cat - <<EOT 1>&2
Usage: $PRGNAME [-c /path/configurationfile] [-m mail_destination] [-D log_directory] [-Fdvh]  [Operation]

       -c /path/configurationfile

       -F : Force a path prefix for MU#0 BCV (MU#1 always uses a prefix)

       -m : mail destination (default: $mailusr)

       -D /path_of_log_directory (default: $dlog)

       -d : debug mode (default is OFF)

       -v : show version and exit

       -h : show help (usage) and exit

       Operation: supported operations are:
                  validate (default)
                  resync
                  split
                  extract
                  mount
		  umount
		  purgelogs <number of days>

     Note that we need at minimum a "-c" option
     ----
EOT
echo 1 > $ERRfile
exit 1
}

# ------------------------------------------------------------------------------
function ValidateOPERATION {
    case $1 in
        validate)    : ;;
        resync)      : ;;
        split)       : ;;
        extract)     : ;;
        mount)       : ;;
        umount)      : ;;
        purgelogs)   : ;;
        reversesync) : ;;
        *)           echo "Unknown OPERATION=$1" ; Usage ;;
    esac
}

# ------------------------------------------------------------------------------
function LogToSyslog {
    # send a line to syslog or messages file with input string
    logger -t $PRGNAME -i "$*"
}

# ------------------------------------------------------------------------------
function MailTo {
    [ -s "$LOGFILE" ] || LOGFILE=/dev/null
    if [[ -n $mailusr ]]; then
        mailx -s "$*" $mailusr < $LOGFILE
    fi
}

# ------------------------------------------------------------------------------
function Revision {
    typeset rev
    rev=$(awk '/Revision/ { print $3 }' $PRGDIR/$PRGNAME | head -1)
    [ -n "$rev" ] || rev="\"Under Development\""
    printf "%s %s\n" $PRGNAME $rev
} # Acquire revision number of the script and plug it into the log file

# ------------------------------------------------------------------------------
function WhoAmI {
    if [ "$(id -u)" != "0" ]; then
        echo "$LOGNAME - You must be root to run script $PRGNAME" 
	echo 1 > $ERRfile
        exit 1
    fi
						}
# ------------------------------------------------------------------------------
function is_var_empty {
    if [ -z "$1" ]; then
	Usage
        echo 1 > $ERRfile
	exit 1
    fi
}

# ------------------------------------------------------------------------------
function Log {
    PREFIX="$(date "+%Y-%m-%d %H:%M:%S") LOG:"
    echo "${PREFIX} $*"
}

# ------------------------------------------------------------------------------
function ErrorLog {
    PREFIX="$(date "+%Y-%m-%d %H:%M:%S") ERROR:"
    echo "${PREFIX} $*" 1>&2
}

# ------------------------------------------------------------------------------
function ErrorExit {
    ErrorLog "$*"
    echo "1" > $ERRfile
    ErrorLog "Exit code 1"
    exit 1
}

# ------------------------------------------------------------------------------
function Note {
    printf " ** $* \n"
}

# ------------------------------------------------------------------------------
function SaveSectionConfigFile {
    # argument 1: SECTION_NAME ; output: temporary file
    sed -e 's/[;#].*$//' \
        -e 's/[[:space:]]*$//' \
        -e 's/^[[:space:]]*//' \
        -e "s/\([^\"']*\)$/\1/" \
        < $CONFIGFILE \
        | sed -n -e "/^\[$1\]/,/^\s*\[/{/^[^;].*/p;}" | sed -e "/\[.*/d" \
        >  /tmp/.section.content
    return 0
}

# ------------------------------------------------------------------------------
function ReadSectionContent {
    # the /tmp/.section.content contains the content for section $1 (arg1)
    # output: 
    [[ ! -f /tmp/.section.content ]] && ErrorExit "No content found for section $1"
    cat /tmp/.section.content
}


# ------------------------------------------------------------------------------
function ParseConfigFile {
    # Investigate the config file and decide if we're dealing with LAYOUT 1.0 or 2.0
    # default LAYOUT="1.0" (to be backwords compatible)
    # argument 1: SECTION_NAME ; output: 
    SaveSectionConfigFile LAYOUT
    LAYOUT="$(ReadSectionContent LAYOUT)"
    [[ -z "$LAYOUT" ]] && LAYOUT="1.0"
    Log "Layout of config file $CONFIGFILE is layout version $LAYOUT"
    case "$LAYOUT" in
        "1.0") . $CONFIGFILE || ErrorExit "Error processing $CONFIGFILE"
               ;;
            *) ParseConfigFileLayout2
               ;;
    esac
}

# ------------------------------------------------------------------------------
function ParseConfigFileLayout2 {
    # LAYOUT=2.0 of CONFIGFILE
    # grab PVOL_INST from its section
    SaveSectionConfigFile PVOL_INST
    PVOL_INST="$(ReadSectionContent PVOL_INST)"
    # grab SVOL_INST from its section
    SaveSectionConfigFile SVOL_INST
    SVOL_INST="$(ReadSectionContent SVOL_INST)"
    # grab BC_TIMEOUT from its section
    SaveSectionConfigFile BC_TIMEOUT
    BC_TIMEOUT="$(ReadSectionContent BC_TIMEOUT)"
    # REMOVE_CLUSTER_MODE from its section
    SaveSectionConfigFile BC_TIMEOUT
    REMOVE_CLUSTER_MODE="$(ReadSectionContent REMOVE_CLUSTER_MODE)"
    # grab SUSPEND_SYNC from its section
    SaveSectionConfigFile SUSPEND_SYNC
    SUSPEND_SYNC="$(ReadSectionContent SUSPEND_SYNC)"
    # grab DEVGRP_VG from its section (could be more then 1 line)
    SaveSectionConfigFile DEVGRP_VG
    set -A DEV_GRP
    set -A VOL_GRP
    i=0
    ReadSectionContent DEVGRP_VG | while read DEVGRP_VG
    do
        DEV_GRP[$i]="$(echo $DEVGRP_VG | awk '{print $1}')"
        VOL_GRP[$i]="$(echo $DEVGRP_VG | awk '{print $2}')" 
        i=$(( i + 1 ))
    done
    # grab EXCLUDE_MOUNTPOINTS from its section (could be more then 1 line)
    SaveSectionConfigFile EXCLUDE_MOUNTPOINTS
    set -A EXCLUDE_MOUNTPOINTS
    i=0
    ReadSectionContent EXCLUDE_MOUNTPOINTS | while read LINE
    do
        EXCLUDE_MOUNTPOINTS[$i]="$LINE"
        i=$(( i + 1 ))
    done
}

# ------------------------------------------------------------------------------
function CheckConfigDir {
    # we should enforce to have at least a sub-dir called "BC"
    echo $1 | grep -q BC
    if [[ $? -eq 1 ]]; then
	Log "WARNING: we prefer a directory name like CONFIGDIR=${1}/BC"
    fi
    if [[ ! -d $1 ]]; then
        ErrorExit "Config Dir: $1 - Missing directory"
    fi
}

# ------------------------------------------------------------------------------
function CheckFailbackConfigDir {
    # arg1: $FAILBACK_CONFIGDIR
    if [[ ! -d ${1} ]]; then
        Log "Creating the FAILBACK_CONFIGDIR=${1}"
	mkdir -m 750 -p ${1}
	chown root:root ${1}
    fi
}

# ------------------------------------------------------------------------------
function CheckConfigFile {
    [[ -z "$PVOL_INST" ]] && { ErrorLog "PVOL_INST not defined in ${CONFIGFILE}"; return 1; }
    [[ -z "$SVOL_INST" ]] && { ErrorLog "SVOL_INST not defined in ${CONFIGFILE}"; return 1; }
    [[ -z "$BC_TIMEOUT" ]] && { ErrorLog "BC_TIMEOUT not defined in ${CONFIGFILE}"; return 1; }
    [[ -z "$DEV_GRP" ]] && { ErrorLog "DEV_GRP not defined in ${CONFIGFILE}"; return 1; }
    [[ -z "$VOL_GRP" ]] && { ErrorLog "VOL_GRP not defined in ${CONFIGFILE}"; return 1; }
    [[ -z "$REMOVE_CLUSTER_MODE" ]] && REMOVE_CLUSTER_MODE=N
    [[ ! -z "$SUSPEND_SYNC" ]] && SUSPEND_SYNC=$( basename $SUSPEND_SYNC )  # remove all paths
    return 0
}

# ------------------------------------------------------------------------------
function ShortVGname {
    # input arg: VOL_GRP[$i]; output: VOL_GRP_s
    VOL_GRP_s=${1#/dev/}     # to be sure about the format we will always strip this variable
    VOL_GRP_s=${VOL_GRP_s%/} # VOL_GRP_s = short Volume Group name without /dev/ and trailing /
    echo "$VOL_GRP_s"
}

# ------------------------------------------------------------------------------
function LongVGname {
    # input: VOL_GRP_s; output: VOL_GRP_l
    echo "/dev/${1}/"
}

# ------------------------------------------------------------------------------
function CreateLockDir {
    mkdir "${LOCKDIR}" >/dev/null 2>/dev/null
    if [[ $? -eq 0 ]]; then
        # create the PIDFILE now
        if echo $PID > $PIDFILE ; then
            Log "lock succeeded: $PID - $PIDFILE"
        else
            Log "Cannot create $PIDFILE (rc=$?)"
            return 1
        fi
    else # else part of mkdir test
        # LOCKDIR already exists
        if [ -f $PIDFILE ]; then
            Log "Found $PIDFILE file - we could be locked..."
            OTHERPID=$(<$PIDFILE)
            if kill -s 0 ${OTHERPID} 2>/dev/null ; then
                Log "locked on ${OTHERPID} - try again"
	        return 1
            else
                Log "lock is stale (${OTHERPID}) - will continue"
            fi
        fi
        if echo $PID > $PIDFILE ; then
            Log "lock succeeded: $PID - $PIDFILE"
        else
            Log "lock failed: $LOCK with rc=$?"
            Log "stop processing"
            return 1
        fi
    fi  # end of mkdir test

    ## check if PIDFILE contains our PID
    CHECKPID=$(<$PIDFILE)
    [[ ${PID} != ${CHECKPID} ]] && return 1   # not successful; try again

    # our PID is effectivily written in the PIFDILE
    return 0
}

function AcquireLock {
    Log "Check if our PID ($PID) is locked"
    CANWEPROCEED=0
    LOCKTAKESTOOLONG=0
    while ( test $CANWEPROCEED -eq 0 )
    do
        LOCKTAKESTOOLONG=$(( LOCKTAKESTOOLONG + 1 ))
        if [[ $LOCKTAKESTOOLONG -gt 1000 ]]; then
            ErrorExit "Waiting on the lock to release takes too long (> $LOCKTAKESTOOLONG seconds)"
        fi
        CreateLockDir && CANWEPROCEED=1
        sleep 1
    done
    return 0
}

function ReleaseLock {
    # remove the lock only if PID is current one
    CHECKPID=$(<$PIDFILE)
    if [[ ${PID} = ${CHECKPID} ]]; then
        # ok we are sure if is our lock
        rm -rf "${LOCKDIR}"
        if [[ $? -eq 0 ]]; then
            Log "Successfully removed the lock directory (${LOCKDIR})"
        else
            Log "We could not remove the lock directory (${LOCKDIR}) due to rm error $?"
        fi
    else
        Log "The lock contains another PID ($CHECKPID) then our effective PID ($PID)"
        Log "We do not remove the lock directory ${LOCKDIR}"
    fi

    return 0
}

# ------------------------------------------------------------------------------
function Validate {
    # Workflow: Validate - basic checks to see whether BC is allowed and/or defined
    CheckRaidMgr # basic checks only
    CheckVgdisplay
    return 0
}

# ------------------------------------------------------------------------------
function CheckRaidMgr {
    IsPairdisplayCmdAvailable
    AnyHorcmConfPresent
    AnyHorcmdRunning
}

# ------------------------------------------------------------------------------
function IsPairdisplayCmdAvailable {
    type -p pairdisplay >/dev/null || ErrorExit "Command pairdisplay not found. Adjust PATH, rc $?."
    return 0
}

# ------------------------------------------------------------------------------
function AnyHorcmConfPresent {
    [[ ! -f /etc/horcm${PVOL_INST}.conf ]] && [[ ! -f /etc/horcm${SVOL_INST}.conf ]] && \
    ErrorExit "No HORCM configuration files found. Is system $lhost ready for Raid Manager?"
    return 0
}

# ------------------------------------------------------------------------------
function AnyHorcmdRunning {
    ps -ef | grep -e horcmd_0${PVOL_INST} -e horcmd_0${SVOL_INST} | grep -v grep >/dev/null || \
    ErrorExit "No horcmd daemons running! Please start it manually via horcmstart.sh command"
    return 0
}

# ------------------------------------------------------------------------------
function CheckVgdisplay {
    type -p vgdisplay >/dev/null || ErrorExit "Command vgdisplay not found. $PRGNAME cannot perform miracles (yet)."
    return 0
}

# ------------------------------------------------------------------------------
function GetMajorMinor {
    # input arg: VOL_GRP_s GRPFILE

    VOL_GRP_l=$( LongVGname $1 )
    Log "GRPFILE=$2"
    Log "Getting Major Minor number: ls -l ${VOL_GRP_l}group"
    ls -l ${VOL_GRP_l}group | awk '{print $5, $6}' > ${GRPFILE} || ErrorExit "Could write Major Minor number into ${GRPFILE}, rc $?"
    [[ ! -s ${GRPFILE} ]] && ErrorExit "${GRPFILE} doesn't exist or empty."

    return 0
}

# ------------------------------------------------------------------------------
function GetMapFile {
    # input args: VOL_GRP_s MAPFILE
    VOL_GRP_s="$1"
    MAPFILE="$2"
    Log "MAPFILE=$MAPFILE"

    if [[ -f ${MAPFILE} ]]
    then Log "Remove existing ${MAPFILE}"
         rm -f ${MAPFILE} || ErrorExit "rm -f ${MAPFILE} failed with rc $?"
    fi

    Log "Create mapfile ${MAPFILE} for ${VOL_GRP_s}"
    vgexport -p -m ${MAPFILE} ${VOL_GRP_s} || ErrorExit "vgexport -p -m failed with rc $?"
    [[ ! -s ${MAPFILE} ]] && ErrorExit "Mapfile ${MAPFILE} not created or empty."

    return 0
}

# ------------------------------------------------------------------------------
function GetMountedFS {
    # input args: VOL_GRP_s FILESYSTEMS
    VOL_GRP_s="$1"
    FILESYSTEMS="$2"
    VOL_GRP_l=$( LongVGname "$VOL_GRP_s" )
    Log "Gather filesystem information for VG /dev/${VOL_GRP_s}" # use VOL_GRP_l to match mount -p output
                                                        # the /,dev=9999xx option is being removed on the fly
    mount -p | grep -v nfs | awk -v VG=${VOL_GRP_l} '$1 ~ VG {
            sub (/[,]dev=[^ ]*/, "", $4);
            print $1, $2, $3, $4}' > ${FILESYSTEMS}
    if [[ $? -ne 0 ]]
        then ErrorExit "Gather filesystem information failed for VG ${VOL_GRP_s}"
    fi

    [[ ! -s ${FILESYSTEMS} ]] && ErrorExit "No filesystem information found for VG ${VOL_GRP_s} in ${FILESYSTEMS}"

    return 0
}

# ------------------------------------------------------------------------------
function Extract {
    # workflow: extract
    Validate  # basic checks

    # first we gonna check if this system is running a P-VOL instance
    HorcmConfFilePresentForInstance $PVOL_INST || ErrorExit "Configuration file /etc/horcm${PVOL_INST}.conf not found on $lhost"
    HorcmdRunningForInstance $PVOL_INST || ErrorExit "Daemon horcmd_0${PVOL_INST} not running on $lhost"
    CheckHorcmConfHostDefined $PVOL_INST && Log "Start extracting source data on $lhost" || \
      ErrorExit "Cannot verify $lhost in HORCM_MON section of /etc/horcm${PVOL_INST}.conf"

    count=${#VOL_GRP[@]}    # count the nr of elements in array
    i=0
    while (( i < count ))
    do
        ExtractSourceData ${VOL_GRP[i]}
        MakeFailbackCopy     # is handy in case of reversesync
        i=$((i+1))
    done
    return 0
}

# ------------------------------------------------------------------------------
function GetMountedFSLinux {
    # input args VOL_GRP_s FILESYSTEMS
    VOL_GRP_s="$1"
    FILESYSTEMS="$2"
    
    Log "Gather filesystem information for VG /dev/${VOL_GRP_s}" # use VOL_GRP_l to match mount -p output
    cat /proc/mounts | grep -v nfs | grep ^/dev/mapper/${VOL_GRP_s}- > ${FILESYSTEMS}
    if [[ $? -ne 0 ]]
        then ErrorExit "Gather filesystem information failed for VG ${VOL_GRP_s}"
    fi

    [[ ! -s ${FILESYSTEMS} ]] && ErrorExit "No filesystem information found for VG ${VOL_GRP_s} in ${FILESYSTEMS}"

    return 0
}

# ------------------------------------------------------------------------------
function ExtractSourceData {
    # input arg: VOL_GRP[i]; output: performed by other functions

    VOL_GRP_s=$( ShortVGname "$1" )
    # define FILESYSTEMS
    FILESYSTEMS=${BASEDIR}/${VOL_GRP_s}.fs
    Log "FILESYSTEMS=${FILESYSTEMS}"
    # also define MAPFILE and GRPFILE variables
    MAPFILE=${BASEDIR}/${VOL_GRP_s}.map
    GRPFILE=${BASEDIR}/${VOL_GRP_s}.grp

    case ${platform} in
        HP-UX)
            GetMajorMinor "$VOL_GRP_s" "$GRPFILE"    || ErrorExit "Couldn't retrieve VG $VOL_GRP_s major/minor."
            GetMapFile "$VOL_GRP_s" "$MAPFILE"       || ErrorExit "Couldn't retrieve VG $VOL_GRP_s map file."
            GetMountedFS "$VOL_GRP_s" "$FILESYSTEMS" || ErrorExit "Couldn't retrieve Filesystem Information of VG $VOL_GRP_s."
            ;;
        Linux)
            GetMountedFSLinux "$VOL_GRP_s" "$FILESYSTEMS" || ErrorExit "Couldn't retrieve Filesystem Information of VG $VOL_GRP_s."
            ;;
    esac

    return 0
}

# ------------------------------------------------------------------------------
function HorcmConfFilePresentForInstance {
    # input arg: PVOL_INST or SVOL_INST; output: 0 (yes) or 1 (false)
    [[ ! -f /etc/horcm${1}.conf ]] && return 1
    return 0
}

# ------------------------------------------------------------------------------
function HorcmdRunningForInstance {
    # input arg: PVOL_INST or SVOL_INST; output: 0 (yes) or 1 (false)
    ps -ef | grep -e horcmd_0${1}$ | grep -v grep >/dev/null || return 1
    return 0
}

# ------------------------------------------------------------------------------
function CheckHorcmConfHostDefined {
    # analyse /etc/horcm${1}.conf and find out if $lhost is the same as what is
    # defined under HORCM_MON section. Could be tricky as IPv4/v6 may be used and some other keywords as NONE/NONE6
    typeset SOURCE_SYSTEM="UNKNOWN"
    grep -v \^# /etc/horcm${1}.conf | awk '/HORCM_MON/,/HORCM_CMD/ {if ($0 !~ "HORCM_MON" && $0 !~ "HORCM_CMD" ) print}'|\
    grep -v '^$' | while read SOURCE_SYSTEM SERVICE POLL TIMEOUT junk
    do
        if [[ "$SOURCE_SYSTEM" = "NONE" ]]; then
	    # HORCM listens to more then 1 subnet (cluster node perhaps)
            : # not yet implemented (return 0)
	elif [[ "$SOURCE_SYSTEM" = "NONE6" ]]; then
	    # HORCM used IPv6 and IPv4 address
            : # not yet implemented
	else
	    # HORCM listens to hostname or IP address
            IsDigit $(echo $SOURCE_SYSTEM | cut -d. -f1) && SOURCE_SYSTEM=$(GetHostnameFromIP $SOURCE_SYSTEM)
	    [[ "$SOURCE_SYSTEM" = "UNKNOWN" ]] && return 1
	    [[ "$SOURCE_SYSTEM" = "$lhost" ]] && return 0
	fi
    done
    return 0
}

# ------------------------------------------------------------------------------
function IsDigit {
    expr "$1" + 1 > /dev/null 2>&1  # sets the exit to non-zero if $1 non-numeric
}

# ------------------------------------------------------------------------------
function GetHostnameFromIP {
    # input is IP address; output hostname
    case ${platform} in
        HP-UX)
             xxx=$(nslookup $1 | grep "^Name:" | awk '{print $2}' 2>/dev/null)
	     ;;
        Linux)
             xxx=$(dig +short -x $1 | cut -d. -f1 2>/dev/null)
	     ;;
    esac
    [[ -z "$xxx" ]] && xxx="UNKNOWN"
    echo $xxx
}

# ------------------------------------------------------------------------------
function Split {
    # workflow: split (should run on the BCV side - S-VOL side)
    Validate   # basic checks
    HorcmConfFilePresentForInstance $SVOL_INST || ErrorExit "Configuration file /etc/horcm${SVOL_INST}.conf not found on $lhost"
    HorcmdRunningForInstance $SVOL_INST || ErrorExit "Daemon horcmd_0${SVOL_INST} not running on $lhost"
    CheckHorcmConfHostDefined $SVOL_INST && Log "Start Splitting S-VOL disks on $lhost" || \
      ErrorExit "Cannot verify $lhost in HORCM_MON section of /etc/horcm${SVOL_INST}.conf"

    count=${#VOL_GRP[@]}    # count the nr of elements in array
    i=0
    while (( i < count ))
    do
        VOL_GRP_s=$( ShortVGname "${VOL_GRP[i]}" )
        VG=$( SetVgName "${VOL_GRP_s}" "${SVOL_INST}" "${DEV_GRP[i]}" )
        PairSplit $VG $SVOL_INST ${DEV_GRP[i]} $BC_TIMEOUT

        LogToSyslog "<info> pairsplit -IBC${SVOL_INST} -g $DEV_GRP (VG $VG) executed with success"

        i=$((i+1))
    done
    return 0
}

# ------------------------------------------------------------------------------
function PairSplit {

    # input args: VG
    typeset VGRP="$1"       # Volume Group to deal with (could be another name)
    typeset HORCMINST="$2"  # SVOL_INST
    typeset DGRP="$3"       # Device Group (as defined in horcm${SVOL_INST}.conf file)
    typeset TIMEOUT="$4"    # BC_TIMEOUT variable

    Log "Check if VG ${VGRP} is inactive."
    IsVolumeGroupActive ${VGRP} && ErrorExit "VG ${VGRP} is already active."
    #vgdisplay ${VGRP} && ErrorExit "VG ${VGRP} is already active."

    Log "Execute: pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx"
    pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx || ErrorExit "Pairdisplay failed with rc $?"

    Log "Execute: pairsplit -IBC${HORCMINST} -g ${DGRP}"
    pairsplit -IBC${HORCMINST} -g ${DGRP} || ErrorExit "Pairsplit failed with rc $?"

    Log "Execute: pairevtwait -IBC${HORCMINST} -g ${DGRP} -t ${TIMEOUT} -s psus -ss ssus"
    pairevtwait -IBC${HORCMINST} -g ${DGRP} -t ${TIMEOUT} -s psus -ss ssus || ErrorExit "Pairevtwait failed with rc $?"

    Log "Execute: pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx"
    pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx || ErrorExit "Pairdisplay failed with rc $?"

    return 0
}

# ------------------------------------------------------------------------------
function CheckBusinessCopyState {
    # input argument ${HORCMINST} ${DEV_GRP}
    # we check the status of the local disks on $lhost
    TMPSTATE=/tmp/BCstate.${PID}
    pairdisplay -IBC${1} -g ${2} -fcd -l -CLI | grep -v ^Group | awk '{print $9}' | sort -u > ${TMPSTATE}
    count=$( wc -l ${TMPSTATE} | awk '{print $1}' )
    if [[ $count -gt 1 ]]; then
        # more then 1 state found (display only the non-expected state)
        grep -v SSUS ${TMPSTATE} | tail -1
    else
        # expected state is SSUS (on BCV side)
        cat ${TMPSTATE}
    fi
    rm -f ${TMPSTATE}
}

# ------------------------------------------------------------------------------
function IsVolumeGroupActive {
    # input arg: VG
    # output: 0(=VG active), or 1(=VG not active)
    typeset VG=$1
    TMPVG=/tmp/vgdisplay-${VG}.${PID}
    rc=0           # assume (default) VG is active
    vgdisplay -v ${VG} > ${TMPVG} 2>&1
    grep -q "Cannot display volume group" ${TMPVG}  && rc=1
    grep -q "is exported" ${TMPVG}                  && rc=1
    grep -q "not found" ${TMPVG}                    && rc=1
    # following case is typical on the P-VOL side(VG active with 0 LVs):
    grep -q "NOT available" ${TMPVG}                && rc=1

    if [[ $rc -eq 0 ]]; then
        Log "VG $VG is active."
    else
        Log "VG $VG is \"not\" active."
    fi
    rm -f ${TMPVG}
    return $rc
}

# ------------------------------------------------------------------------------
function ListRawDevicesForImport {
    # input args: ${SVOL_INST} ${DEV_GRP}
    # output args: raw devices belonging to ${DEV_GRP}
    typeset RAWDISKS=""
    # list of disks, e.g. disk30 disk33
    pairdisplay -IBC${1} -g ${2} -fcd | grep "(L)" | awk '{print $3}' >/tmp/BC_local_devs.$PID
    for DISK in $( cat /tmp/BC_local_devs.$PID )
    do
        RAWDISKS="$RAWDISKS $(CharDevOfDiskIs $DISK)"
    done
    rm -f /tmp/BC_local_devs.$PID
    echo $RAWDISKS
}

# ------------------------------------------------------------------------------
function CharDevOfDiskIs {
    # input arg: disk; output is character device (full path)
    if [[ -c /dev/rdisk/${1} ]]; then
        echo "/dev/rdisk/${1}"
    elif [[ -c /dev/rcdisk/${1} ]]; then
	echo "/dev/rcdisk/${1}"
    elif [[ -c /dev/rdsk/${1} ]]; then
	echo "/dev/rdsk/${1}"
    else
        echo "${1}"    # character device not identified (return input as is)
    fi
}

# ------------------------------------------------------------------------------
function FindFreeMinorNr {
    # input: MajNr; output: free minor number (hex)
    # minor number layout for group file
    # 64 0xnn0000  128 0xnnn000
    typeset  MajNr=${1}
    typeset  i
    i=$( ls -l /dev/*/group | grep "  ${MajNr}" | awk '{print $6}' | sort | tail -1 )
    case ${MajNr} in
	64 ) j=$( echo $i | sed -e 's/^0x//' -e 's/0000$//' ) ;;
	128) j=$( echo $i | sed -e 's/^0x//' -e 's/000$//' )  ;;
    esac

    j=$( echo $j | tr '[:lower:]' '[:upper:]' )     # rewrite HEX nr in capital
    j=$( echo "ibase=16; $j" | bc )                 # convert to decimal
    x=$( printf "%X\n" $((${j} + 1)) )              # add 1 and convert back to HEX

    charlength=$( expr $(echo $x | wc -c) - 1 )     # remove the \nl
    case ${MajNr} in
	64 )
	    case $charlength in
                1) str="0${x}0" ;;
		2) str="${x}0"  ;;
	    esac
	    ;;
	128)
	    case $charlength in
	       1) str="00${x}" ;;
	       2) str="0${x}"  ;;
	       3) str="${x}"   ;;
	    esac
	    ;;
    esac
    echo "0x${str}000"
}

# ------------------------------------------------------------------------------
function ActivateVGonHPUX {
    # input args: VOL_GRP_s DEV_GRP HORCMINST
    typeset VG="$1"
    typeset DGRP="$2"
    typeset HORCMINST="$3"

    MAPFILE=${BASEDIR}/${VOL_GRP_s}.map
    GRPFILE=${BASEDIR}/${VOL_GRP_s}.grp

    ##VG=$( SetVgName "${VOL_GRP_s}" "${HORCMINST}" "${DGRP}" )

    Log "MAPFILE=${MAPFILE}"
    Log "Check if we have a map file for VG ${VG}."
    [[ ! -s ${MAPFILE} ]] && ErrorExit "Mapfile ${MAPFILE} missing."

    Log "GRPFILE=${GRPFILE}"
    Log "Check if we have a group file for VG ${VG}."
    [[ ! -s ${GRPFILE} ]] && ErrorExit "Group file ${GRPFILE} missing."

    Log "Check if VG ${VG} is inactive."
    IsVolumeGroupActive ${VG} && ErrorExit "VG ${VG} is already active."

    if [[ -d /dev/${VG} ]]; then
        Log "Directory /dev/${VG} already exists"
    else
        Log  "mkdir -p -m 755 /dev/${VG}"
        mkdir -p -m 755 /dev/${VG} || ErrorExit "mkdir /dev/${VG} failed with rc $?"
    fi

    # Read the major number of VG from groupfile
    MajNr=$( cat $GRPFILE | awk '{print $1}' )
    IsDigit $MajNr || ErrorExit "Major Number $MajNr is not a digit"

    # Check if the VG/group already exists? 
    if [[ -c /dev/${VG}/group ]]; then
        Log "/dev/${VG}/group already exists"
    else
        AcquireLock # The following piece of code may not be executed by two jobs at the same time
		    # otherwise they will create duplicate minor numbers - which is FATAL.
        MinNr=$( FindFreeMinorNr $MajNr ) 
        Log "Create the /dev/${VG}/group file"
        mknod /dev/${VG}/group c $MajNr $MinNr || ErrorExit "mknod /dev/${VG}/group c $MajNr $MinNr failed with rc $?"
        ReleaseLock # Release the lock if possible (non fatal)
    fi
    Log "Major, minor VG nrs are $(ls -l /dev/${VG}/group | awk '{print $5, $6, $10}')"

    # collect the raw devices needed for the vgimport/vgchgid
    RawDevs=$( ListRawDevicesForImport ${HORCMINST} ${DGRP} )
    PlainDevs=$( echo $RawDevs | sed -e 's#/dev/rd#/dev/d#g' )

    # do the vgchgid now
    Log "Change the VG id on /dev/$VG"
    vgchgid ${RawDevs} || ErrorExit "vgchgid ${RawDevs} failed with rc $?."

    # do the vgimport
    Log "Import $VG via mapfile ${MAPFILE}"
    vgimport -v -m ${MAPFILE} ${VG} ${PlainDevs} || ErrorExit "vgimport $VG failed with rc $?."

    Log "vgchange -c n if REMOVE_CLUSTERMODE(${REMOVE_CLUSTER_MODE}) = Y"
    if [[ "${REMOVE_CLUSTER_MODE}" = "Y" ]]; then
        vgchange -c n ${VG} || ErrorExit "vgchange -c n $VG failed with rc $?."
    fi

    Log "Activating VG ${VG}."
    vgchange -a y ${VG} || ErrorExit "vgchange -a y $VG failed with rc $?."

    return 0
}

# ------------------------------------------------------------------------------
function GetMpathDevs {
    DEVS=""
    for dev in $*
    do
      DEVS="$DEVS /dev/mapper/"$( multipath -l /dev/${dev} | head -1 | cut -d' ' -f1 )
    done

    echo "$DEVS"
}

# ------------------------------------------------------------------------------
function RestartHorcmDaemon {
    # on Linux only! The disk device name may change after a FC glitch. Therefore,
    # to be sure we catch the correct device name we better restart the horcmd daemon
    # before running pairdisplay -d << to see actual device names
    # should only run on BCV side - SVOL side
    typeset HORCMINST="$1"
    Log "Restarting HORCM instance $HORCMINST to insure correct device names"
    horcmshutdown.sh $HORCMINST
    horcmstart.sh  $HORCMINST
    HorcmdRunningForInstance $HORCMINST || ErrorExit "Daemon horcmd_0${HORCMINST} not running on $lhost"
}

# ------------------------------------------------------------------------------
function ActivateVGonLinux {
    # input args: VOL_GRP_s DEV_GRP HORCMINST
    typeset VG="$1"
    typeset DGRP="$2"
    typeset HORCMINST="$3"

    ##VG=$( SetVgName "${VOL_GRP_s}" "${HORCMINST}" "${DGRP}" )

    # acquire a lock before doing GetMpathDevs (and in particular multipath command to avoid
    # empty output when multiple commands are budy). Move the AcquireLock to Mount function for linux,
    # otherwise, the restart of the HORCM daemon will generates issues at multiple start-ups
    # AcquireLock
    # collect the raw devices needed for the vgimport/vgchgid
    RawDevs=$( ListRawDevicesForImport ${HORCMINST} ${DGRP} )
    MpathDevs=$( GetMpathDevs ${RawDevs} )
    ReleaseLock

    #Log "ImportClone VG ${VG} with ${MpathDevs}."
    #vgimportclone -d --basevgname ${VG} --import ${MpathDevs}

    Log "Check if VG ${VG} is inactive."
    IsVolumeGroupActive ${VG} && ErrorExit "VG ${VG} is already active."

    Log "Check if devices (${MpathDevs}) are LVM PVs"
    CheckMpathDevs ${MpathDevs}      # VGname_orig gets defined here

    Log "Change UUID of the devices (${MpathDevs})"
    VgChangeUuid ${MpathDevs}

    Log "Change UUID of VG ${VG}"
    vgchange --uuid  ${VG} --config 'global{activation=0}'
 
    # when the VG was previously exported then we need to import it back
    vgdisplay ${VG} 2>&1 | grep -iq "is exported"
    if [[ $? -eq 0 ]]; then
        Log "vgimport VG ${VG}"
        vgimport -v  ${VG}
    else
        # vgrename VG vgBC1_vgplulogs to vgplulogs
        Log "vgrename VG $VGname_orig to $VG"
        vgrename $VGname_orig $VG
    fi

    # could be that the VG are still exported after the renaming
    vgdisplay ${VG} 2>&1 | grep -iq "is exported"
    if [[ $? -eq 0 ]]; then
        # import is necessary so we can acitvate the VG
        Log "vgimport VG ${VG}"
        vgimport -v  ${VG}
    fi

    Log "vgscan"
    vgscan --mknodes

    Log "Activating VG ${VG}"
    vgchange -a n ${VG}  2>/dev/null
    vgchange -a y ${VG} || ErrorExit "vgchange -a y $VG failed with rc $?."

    return 0
}

# ------------------------------------------------------------------------------
function CheckMpathDevs {
    # input args $MpathDevs
    > /tmp/VGname-of-PV.$PID   # empty file to write VG name in
    for dev in $(echo $*)
    do
        pvdisplay $dev 2>/dev/null | grep -iq "PV Name" || ErrorExit "Devive $dev is not a LVM PV"
        pvdisplay $dev 2>/dev/null | grep -i "VG Name" | awk '{print $3}' >> /tmp/VGname-of-PV.$PID
    done

    countVG=$( cat /tmp/VGname-of-PV.$PID | sort | uniq | wc -l )
    [[ $countVG -ne 1 ]] && ErrorExit "The physical volumes belong to more then 1 VG"
    VGname_orig=$( cat /tmp/VGname-of-PV.$PID | sort | uniq )
    export VGname_orig
 
    return 0
}

# ------------------------------------------------------------------------------
function VgChangeUuid {
    # input args $MpathDevs
    for dev in $(echo $*)
    do
        pvchange --uuid $dev --config 'global{activation=0}' || ErrorExit "Cannot change UUID of Devive $dev"
    done

    return 0
}

# ------------------------------------------------------------------------------
function Mount {
    # workflow: mount
    Validate
    # we must run this on the S-VOL side
    HorcmConfFilePresentForInstance $SVOL_INST || ErrorExit "Configuration file /etc/horcm${SVOL_INST}.conf not found on $lhost"
    HorcmdRunningForInstance $SVOL_INST || ErrorExit "Daemon horcmd_0${SVOL_INST} not running on $lhost"
    CheckHorcmConfHostDefined $SVOL_INST && Log "Start mounting S-VOL disks on $lhost" || \
      ErrorExit "Cannot verify $lhost in HORCM_MON section of /etc/horcm${SVOL_INST}.conf"

    count=${#VOL_GRP[@]}    # count the nr of elements in array
    i=0
    while (( i < count ))
    do

        VOL_GRP_s=$( ShortVGname "${VOL_GRP[i]}" )
        VG=$( SetVgName "${VOL_GRP_s}" "${SVOL_INST}" "${DEV_GRP[i]}" )
        FILESYSTEMS=${BASEDIR}/${VOL_GRP_s}.fs

        case ${platform} in
            HP-UX) ActivateVGonHPUX "$VG" "${DEV_GRP[i]}" "${SVOL_INST}" ;;
            Linux) AcquireLock
                   RestartHorcmDaemon ${SVOL_INST}
                   ActivateVGonLinux "$VG" "${DEV_GRP[i]}" "${SVOL_INST}" ;;
        esac

        BCState=$( CheckBusinessCopyState ${SVOL_INST} ${DEV_GRP[i]} )
        [[ "$BCState" != "SSUS" ]] && ErrorExit "BC State is ${BCState}. Disks must be splitted before the \"mount\" workflow."

        [[ ! -s ${FILESYSTEMS} ]] && ErrorExit "No filesystem information available for VG ${VG} in ${FILESYSTEMS}"

        MNTPREFIX=$( SetMntPrefixPath ${VOL_GRP_s} ${SVOL_INST} ${DEV_GRP[i]} )

        while read lvol fs_mnt fs_typ fs_opt
        do
            RemoveExcludedFilesystems "$fs_mnt" && continue
            MountFS /dev/${VG}/${lvol##*/} ${MNTPREFIX}${fs_mnt} ${fs_typ} "${fs_opt}" 
	    rc=$?
	    if [[ $rc -ne 0 ]]; then
                ErrorLog "Mount ${MNTPREFIX}${fs_mnt} failed with rc $rc"
	        echo 1 > $ERRfile
	        # now run the UnMount operation to get rid of the VG again
	        Log "Force an \"umount\" operation to remove the $VG" 
	        UnMount
	        ErrorExit "The \"mount\" operation was \"not\" successful."
            fi
        done < ${FILESYSTEMS}

        LogToSyslog "<info> Mounted $VG on top of /${MNTPREFIX} with success"

        # make a copy of all files found under CONFIGDIR to FAILBACK_CONFIGDIR
        MakeFailbackCopy      # return code always 0

        i=$((i+1))

    done
    return 0
}

# ------------------------------------------------------------------------------
function MountFS {
    # input args: lvol ${MNTPREFIX}${fs_mnt} ${fs_typ} "${fs_opt}"
    typeset lvol=$1
    typeset fs_mnt=$2
    typeset fs_typ=$3
    typeset fs_opt="$4"
    # Create the mountpoint ---
    if [[ -d "${fs_mnt}" ]]; then
        Log "Using existing mount point ${fs_mnt}."
    else
	Log "Creating mount point ${fs_mnt}."
	mkdir -p -m 755 ${fs_mnt} || ErrorExit "mkdir failed with rc $?"
    fi
    [[ ! -d "${fs_mnt}" ]] && ErrorExit "Mount point ${fs_mnt} doesn't exist."

    case ${platform} in
        HP-UX)
             # Run Filesystem Check ---
             Log "Running fsck on ${lvol}"
             fsck -F ${fs_typ} -y ${lvol} || ErrorExit "fsck ${lvol} failed with rc $?"

             # Mount the filesystem ---
             Log "Mounting -F ${fs_typ} -o ${fs_opt} ${lvol} ${fs_mnt}"
             mount -F ${fs_typ} -o ${fs_opt} ${lvol} ${fs_mnt} || return 1
             ;;       

        Linux)
             # Run Filesystem Check ---
             # $lvol on Linux is /dev/vgBC1_vgpludata/vgpludata-lvplud01 (original system)
             # on BCV it looks like /dev/vgBC1_vgpludata/lvplud01
             vg=${lvol%/*}      # /dev/vgBC1_vgpludata
             lv=${lvol##*/}     # vgpludata-lvplud01
             lv=${lv#*-}        # lvplud01
             Log "Running fsck on ${vg}/${lv}"
             fsck -y ${vg}/${lv} 
             case $? in
                0) : ;; # no errors
                1) ErrorLog "fsck ${vg}/${lv} failed with rc $? - File system errors corrected" ;; # we continue anyway
                2) ErrorExit "fsck ${vg}/${lv} failed with rc $? - System should be rebooted" ;;
                4) ErrorExit "fsck ${vg}/${lv} failed with rc $? - File system errors left uncorrected" ;;
                8) ErrorExit "fsck ${vg}/${lv} failed with rc $? - Operational error" ;;
               16) ErrorExit "fsck ${vg}/${lv} failed with rc $? - Usage or syntax error" ;;
               32) ErrorExit "fsck ${vg}/${lv} failed with rc $? - Fsck canceled by user request" ;;
              128) ErrorExit "fsck ${vg}/${lv} failed with rc $? - Shared library error" ;;
             esac

             # Mount the filesystem ---
             # fs_opt contains spaces - get rid of them
             Log "Mounting -t ${fs_typ} -o ${fs_opt%% *} ${vg}/${lv} ${fs_mnt}"
             mount -t ${fs_typ} -o ${fs_opt%% *} ${vg}/${lv} ${fs_mnt} || return 1
             ;;
    esac

    return 0
}

# ------------------------------------------------------------------------------
function SetVgName {
    # define the VG name for BCV - input args  ${VOL_GRP_s} ${SVOL_INST} ${DEV_GRP}
    # we propose as standard: vgBC${SVOL_INST}_${DEV_GRP}
    echo "vgBC${2}_${3}"
}

# ------------------------------------------------------------------------------
function UnMount {
    # workflow: unmount (should be executed on the S-VOL side)
    Validate   # basic checks
    HorcmConfFilePresentForInstance $SVOL_INST || ErrorExit "Unmount may only be executed on S-VOL (HORCM instance ${SVOL_INST}) side"

    count=${#VOL_GRP[@]}    # count the nr of elements in array
    i=0
    while (( i < count ))
    do

        VOL_GRP_s=$( ShortVGname "${VOL_GRP[i]}" )
        VG=$( SetVgName ${VOL_GRP_s} ${SVOL_INST} ${DEV_GRP[i]} )
        FILESYSTEMS=${BASEDIR}/${VOL_GRP_s}.fs

        Log "Check if VG ${VG} is active."
        IsVolumeGroupActive ${VG}      # 0 means still active
        if [[ $? -ne 0 ]]; then
            IsVolumeGroupInError ${VG} || return 0 # nothing we can do, so return 
        fi 

        [[ ! -s ${FILESYSTEMS} ]] && ErrorExit "No filesystem information available for VG ${VG} in ${FILESYSTEMS}"

        MNTPREFIX=$( SetMntPrefixPath ${VOL_GRP_s} ${SVOL_INST} ${DEV_GRP[i]} )

        while read lvol fs_mnt fs_typ fs_opt
        do
	     RemoveExcludedFilesystems "$fs_mnt" && continue
             IsFsMounted "${MNTPREFIX}${fs_mnt}" && UnMountFS ${MNTPREFIX}${fs_mnt}
        done < ${FILESYSTEMS}

        case ${platform} in
            HP-UX) VgExportonHPUX $VG ;;
            Linux) VgExportonLinux $VG ;;
        esac

        LogToSyslog "<info> vgexport ${VG} executed with success"

        i=$((i+1))

    done
    return 0
}

# ------------------------------------------------------------------------------
function IsVolumeGroupInError {
    # IsVolumeGroupActive function returned not active, but in fact we have an error as shown below:
    # vgdisplay: Couldn't query volume group "/dev/vgBC1_vgSORA1".
    # Possible error in the Volume Group minor number; Please check and make sure the group minor number is unique.
    # vgdisplay: Cannot display volume group "/dev/vgBC1_vgSORA1".
    VG="$1"
    TMPVG=/tmp/vgdisplay-${VG}.${PID} 
    vgdisplay ${VG} > ${TMPVG} 2>&1
    Log "Volume Group $VG is in weird state:"
    cat ${TMPVG}

    grep -q "Couldn\'t query volume group" ${TMPVG}
    if [[ $? -eq 0 ]]; then
	# let's treat this VG as still active
	rc=0
    else
	if [[ -c /dev/${VG}/group ]]; then
            Log "Remove character device /dev/${VG}/group (in function IsVolumeGroupInError)"
	    rm -f /dev/${VG}/group
	fi
        rc=1
    fi
    rm -f ${TMPVG}
    return $rc
}

# ------------------------------------------------------------------------------
function VgExportonHPUX {
    # input arg: VG; output: rc or bail out
    VG="$1"
    Log "De-activating VG ${VG}"
    $DEBUG vgchange -a n ${VG} || ErrorLog "vgchange -a n $VG failed with rc $?"

    Log "Export the VG ${VG}"
    $DEBUG vgexport -v ${VG}
    rc=$?
    if [[ $rc -ne 0 ]]; then
        # check if the directory has really been removed
        if [[ -d /dev/${VG} ]]; then
            Log "vgexport did not remove the /dev/${VG} directory! See the content:"
	    ls -l /dev/${VG}
        fi
	ErrorLog "vgexport ${VG} failed with rc $rc"
    fi

    # at least make sure the group file is deleted.
    if [[ -c /dev/${VG}/group ]]; then
        Log "Remove /dev/${VG}/group character device"
	$DEBUG rm -f /dev/${VG}/group
    fi
    return 0
}

# ------------------------------------------------------------------------------
function VgExportonLinux {
    # input arg: VG; output: rc or bail out
    VG="$1"
    # cleanup devices under device-mapper directory
    ls /dev/mapper/${VG}-* >/dev/null 2>/dev/null
    if [[ $? -eq 0 ]]; then
        Log "dmsetup remove /dev/mapper/${VG}-*"
        $DEBUG dmsetup remove /dev/mapper/${VG}-*
    fi

    vgdisplay ${VG} 2>&1 | grep -iqE "(is exported|not found)"
    if [[ $? -eq 0 ]]; then
        Log "VG ${VG} was already exported"
    else
        Log "De-activating VG ${VG}"
        $DEBUG vgchange -a n ${VG} || ErrorExit "vgchange -a n $VG failed with rc $?"
    
        Log "Export the VG ${VG}"
        $DEBUG vgexport -v ${VG} || ErrorExit "vgexport ${VG} failed with rc $?"
    fi


    if [[ -d /dev/${VG} ]]; then
        Log "Remove dangling /dev/${VG}/ files"
        $DEBUG rm -rf /dev/${VG}
    fi
    if [[ -f /etc/lvm/backup/${VG} ]]; then
        Log "Remove /etc/lvm/backup/${VG} file"
        $DEBUG rm -f /etc/lvm/backup/${VG}
    fi
}

# ------------------------------------------------------------------------------
function RemoveExcludedFilesystems {
    # EXCLUDE_MOUNTPOINTS variable from config file
    for mntpt in ${EXCLUDE_MOUNTPOINTS[@]}
    do
        [[ "$mntpt" = "$1" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------------------------
function SetMntPrefixPath {
    # Do we define a path prefix for mounting BCV? $FORCE_MOUNT_PREFIX triggers this
    # args: ${VOL_GRP_s} ${SVOL_INST} ${DEV_GRP}
    # output: define our standard /mnt/vgBC${SVOL_INST}_${DEV_GRP}
    if [[ -z "$FORCE_MOUNT_PREFIX" ]]; then
	echo ""
    else
	echo "/mnt/vgBC${2}_${3}"
    fi
}

# ------------------------------------------------------------------------------
function IsFsMounted {
    #df -Pl | awk '{print $6}' | grep -q "${1}$" && return 0 || return 1
    # to avoid NFS hangs use mount instead
    mount -v | awk '{print $3}' | grep -q "${1}$" && return 0 || return 1
}

# ------------------------------------------------------------------------------
function UnMountFS {
    ## Next line does not work all the time - be a bit more slower and safer
    ## $DEBUG umount $1 || KillProcessHoldingFS $1 || ErrorExit "Unmount failed with rc $?."
    Log "Umount file system $1"
    $DEBUG umount $1
    if [[ $? -gt 0 ]]; then
	# kill processes using the FS using fuser
	KillProcessHoldingFS $1
	if [[ $? -eq 0 ]]; then
	    sleep 3     # give processes some extra time to die
	    # try an umount again (forced)
	    $DEBUG umount  $1
	    if [[ $? -gt 0 ]]; then
		# one more time, but try a really hard forced/lazy umount
		ForcedUnMount $1 || ErrorLog "Unmount failed with rc $?"
	    fi
        else
	    # KillProcessHoldingFS was not successful - try a really hard forced umount
	    ForcedUnMount $1 || ErrorLog "Unmount failed with rc $?"
	fi
    fi

    return 0
}

# ------------------------------------------------------------------------------
function ForcedUnMount {
    # arg: FS
    case ${platform} in
        HP-UX) $DEBUG /sbin/fs/vxfs/vxumount -o force $1 || return 1 ;;
        Linux) $DEBUG umount -l $1 || return 1 ;;
        *) return 1 ;;
    esac

    return 0
}

# ------------------------------------------------------------------------------
function KillProcessHoldingFS {
    # the purpose is to run fuser on a FS that return "device busy"
    # before doing an ErrorExit
    Log "File system $1 returned Device Busy - try to kill the processes"
    fuser -ku $1 && return 0 || return 1
}

# ------------------------------------------------------------------------------
function Resync {
    # workflow: resync
    Validate
    HorcmConfFilePresentForInstance $SVOL_INST || ErrorExit "Configuration file /etc/horcm${SVOL_INST}.conf not found on $lhost"
    HorcmdRunningForInstance $SVOL_INST || ErrorExit "Daemon horcmd_0${SVOL_INST} not running on $lhost"
    CheckHorcmConfHostDefined $SVOL_INST && Log "Start Pair Resync S-VOL disks on $lhost" || \
    ErrorExit "Cannot verify $lhost in HORCM_MON section of /etc/horcm${SVOL_INST}.conf"

    count=${#VOL_GRP[@]}    # count the nr of elements in array
    i=0
    while (( i < count ))
    do

        VOL_GRP_s=$( ShortVGname "${VOL_GRP[i]}" )
        VG=$( SetVgName "${VOL_GRP_s}" "${SVOL_INST}" "${DEV_GRP[i]}" )
        PairResync $VG $SVOL_INST ${DEV_GRP[i]} $BC_TIMEOUT

        LogToSyslog "<info> pairresync -IBC${SVOL_INST} -g ${DEV_GRP[i]} (VG $VG) executed with success"
        i=$((i+1))
    done
    return 0

}

# ------------------------------------------------------------------------------
function IsVgStillActive {
    # input arg: VG ; output: 0 (active) - 1 (exported)
    case ${platform} in
        HP-UX)
                 vgdisplay ${1} || return 1
                 ;;
        Linux)
                 if vgdisplay ${1}; then 
                   vgs --noheadings -o attr  ${1} | grep -q "x" && return 1
                 else
                   return 1
                 fi
                 ;;
    esac
    return 0
}

# ------------------------------------------------------------------------------
function PairResync {
    # input args: $VG $SVOL_INST $DEV_GRP $BC_TIMEOUT
    typeset VGRP="$1"       # Volume Group to deal with (could be another name)
    typeset HORCMINST="$2"  # SVOL_INST
    typeset DGRP="$3"       # Device Group (as defined in horcm${SVOL_INST}.conf file)
    typeset TIMEOUT="$4"    # BC_TIMEOUT variable

    [[ ! -z "${SUSPEND_SYNC_FLAG}" ]] && ErrorExit "SUSPEND_SYNC_FLAG flag [$SUSPEND_SYNC_FLAG] was set"

    Log "Check if VG ${VGRP} is inactive."
    #vgdisplay ${VGRP} && ErrorExit "VG ${VGRP} is still active."
    IsVgStillActive ${VGRP} && ErrorExit "VG ${VGRP} is still active."

    Log "Execute: pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx"
    pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx || ErrorExit "Pairdisplay failed with rc $?"

    Log "Execute: pairresync -IBC${HORCMINST} -g ${DGRP}"
    pairresync -IBC${HORCMINST} -g ${DGRP} || ErrorExit "Pairresync failed with rc $?"

    Log "Execute: pairevtwait -IBC${HORCMINST} -g ${DGRP} -t $((TIMEOUT * 12)) -s pair -ss pair"
    pairevtwait -IBC${HORCMINST} -g ${DGRP} -t $((TIMEOUT * 12)) -s pair -ss pair || ErrorExit "Pairevtwait failed with rc $?"

    Log "Execute: pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx (should show PAIR)"
    pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx || ErrorExit "Pairdisplay failed with rc $?"

    return 0

}

# ------------------------------------------------------------------------------
function PairReverseResync {
    # input args: $VG $PVOL_INST $DEV_GRP $BC_TIMEOUT
    typeset VGRP="$1"       # Volume Group to deal with (could be another name)
    typeset HORCMINST="$2"  # PVOL_INST
    typeset DGRP="$3"       # Device Group (as defined in horcm${PVOL_INST}.conf file)
    typeset TIMEOUT="$4"    # BC_TIMEOUT variable

    [[ -z "${SUSPEND_SYNC_FLAG}" ]] && ErrorExit "SUSPEND_SYNC_FLAG flag [$SUSPEND_SYNC_FLAG] was NOT set"

    Log "Check if VG ${VGRP} is inactive."
    IsVgStillActive ${VGRP} && ErrorExit "VG ${VGRP} is still active."

    Log "Execute: pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx"
    pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx || ErrorExit "Pairdisplay failed with rc $?"

    Log "Execute: pairresync -IBC${HORCMINST} -g ${DGRP} -restore"
    pairresync -IBC${HORCMINST} -g ${DGRP} -restore || ErrorExit "Pairresync failed with rc $?"

    Log "Execute: pairevtwait -IBC${HORCMINST} -g ${DGRP} -t $((TIMEOUT * 12)) -s pair -ss pair"
    pairevtwait -IBC${HORCMINST} -g ${DGRP} -t $((TIMEOUT * 12)) -s pair -ss pair || ErrorExit "Pairevtwait failed with rc $?"

    Log "Execute: pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx (should show PAIR)"
    pairdisplay -IBC${HORCMINST} -g ${DGRP} -fcx || ErrorExit "Pairdisplay failed with rc $?"

    LogToSyslog "<warn> pairresync -IBC${HORCMINST} -g ${DGRP} -restore"
    return 0
}

# ------------------------------------------------------------------------------
function CheckSuspendSyncFlag {
     # input arg: CONFIGDIR, output: filename of suspend-file or empty string (normal mode)
     # Be careful: we check only in $BASEDIR (=CONFIGDIR or FAILBACK_CONFIGDIR)
     # we will look for a file under BASEDIR with name ${PKGNAME%.*}.suspend  = dbp0005_BC0.supend
     if [[ -f ${1}/$SUSPEND_SYNC ]]; then
         SUSPEND_SYNC_FLAG=$SUSPEND_SYNC
     elif [[ -f ${1}/${PKGNAME%.*}.suspend ]]; then
         SUSPEND_SYNC_FLAG=${PKGNAME%.*}.suspend
     fi
     return 0
}

# ------------------------------------------------------------------------------
function MakeFailbackCopy {
    CheckFailbackConfigDir  $FAILBACK_CONFIGDIR           # create the failback dir if needed
    [[ "$BASEDIR" = "$FAILBACK_CONFIGDIR" ]] && return    # we are using the failback right now 
    if [[ -d $BASEDIR ]]; then
	Log "Making a copy of all files under $BASEDIR to $FAILBACK_CONFIGDIR"
        find $BASEDIR -type f -exec cp -f {} $FAILBACK_CONFIGDIR \;
    fi

    return 0
}

# ------------------------------------------------------------------------------
function PurgeLogs {
    # to remove BC-exec log files older then $PurgeOlderThenDays
    /usr/bin/find $dlog -name "*BC-exec*" -type f -mtime +${PurgeOlderThenDays}  -print -exec rm -f {} \;
    return 0
}

# ------------------------------------------------------------------------------
function Cleanup {
    rm -f $ERRfile
    [[ -f ./mapfile ]] && rm -f ./mapfile
    rm -f /tmp/.section.content
    return 0
}

# ------------------------------------------------------------------------------
function ReverseSync {
    # Reverse Sync is the operation of resyncing S-Vol to P-Vol (the reverse of
    # a normal BC Resync). We will enforce to execute this on the P-Vol side as
    # we need to check if there is any application running on these VGs
    [ $(tty -s; echo $?) ] || Error "The reversync operation must be run interactively"

    Validate
    HorcmConfFilePresentForInstance $PVOL_INST || ErrorExit "Configuration file /etc/horcm${PVOL_INST}.conf not found on $lhost"
    HorcmdRunningForInstance $PVOL_INST || ErrorExit "Daemon horcmd_0${PVOL_INST} not running on $lhost"
    CheckHorcmConfHostDefined $PVOL_INST && Log "Start ReverseSync S-VOL to P-VOL disks on $lhost" || \
    ErrorExit "Cannot verify $lhost in HORCM_MON section of /etc/horcm${PVOL_INST}.conf"

    # let show some warning messages
    ShowStopPackagesWarning || InterruptReverseSync

    # loop over the different VGs and DevGrps
    count=${#VOL_GRP[@]}    # count the nr of elements in array
    i=0
    while (( i < count ))
    do
        # the DEV_GRP may not be mounted on S-VOL side otherwise cntl files issues with oracle
        ShowBcvMountWarning "$PVOL_INST" "$SVOL_INST" "${VOL_GRP[i]}" "${DEV_GRP[i]}" || InterruptReverseSync
        i=$((i+1))
    done


    # set the suspend flag to avoid resyncs on the BVC server
    CheckSuspendSyncFlag ${BASEDIR}         # if not empty (filename) it is set, otherwise it is empty
    if [[ -z "$SUSPEND_SYNC_FLAG" ]]; then
        Log "Suspend flag was not set! It is a basic requirement for the reversesync. We will do it for you"
        SUSPEND_SYNC_FLAG=${PKGNAME%.*}.suspend
        touch "/tmp/$SUSPEND_SYNC_FLAG"  # do in in /tmp as BASEDIR may be part of the package
        Log "Suspend Flag SUSPEND_SYNC_FLAG=$SUSPEND_SYNC_FLAG defined"
    else
        # the suspend flag was already set - we need to be careful when remove it again!!!
        touch "/tmp/do_not_remove_suspend_flag_by_reversesync"
    fi

    ### the work horse : reverseresync
    count=${#VOL_GRP[@]}    # count the nr of elements in array
    i=0

    while (( i < count ))
    do

        VOL_GRP_s=$( ShortVGname "${VOL_GRP[i]}" )

        # check if the P-vol/S-vol are splitted
        BCState=$( CheckBusinessCopyState ${PVOL_INST} ${DEV_GRP[i]} )
        [[ "$BCState" != "PSUS" ]] && ErrorExit "BC State is ${BCState}. Disks must be splitted before the \"reversesync\" operation."

        # we can start the vgexport here
        VG=${VOL_GRP_s}
        Log "Check if VG ${VG} is still active"
        IsVolumeGroupActive ${VG}      # 0 means still active
        if [[ $? -eq 0 ]]; then
            ErrorExit "Volume group $VG is active! It should be de-activated first!"
        fi

        case ${platform} in
            HP-UX) VgExportonHPUX $VG ;;
            Linux) VgExportonLinux $VG ;;
        esac

        LogToSyslog "<info> vgexport ${VG} executed with success"

        # do the reverse sync
        Log "PairReverseResync $VG $PVOL_INST ${DEV_GRP[i]} $BC_TIMEOUT"
        PairReverseResync $VG $PVOL_INST ${DEV_GRP[i]} $BC_TIMEOUT

        # Split the PAIR again for safety reasons
        Log "PairSplit $VG $PVOL_INST ${DEV_GRP[i]} $BC_TIMEOUT"
        PairSplit $VG $PVOL_INST ${DEV_GRP[i]} $BC_TIMEOUT

        # rebuild the VG again (from scratch)
        case ${platform} in
            HP-UX) ActivateVGonHPUX "$VG" "${DEV_GRP[i]}" "${PVOL_INST}" ;;
            Linux) AcquireLock
                   RestartHorcmDaemon ${PVOL_INST}
                   ActivateVGonLinux "$VG" "${DEV_GRP[i]}" "${PVOL_INST}" ;;
        esac

        Log "Check if VG ${VG} is active."
        IsVolumeGroupActive ${VG}
        if [[ $? -eq 0 ]]; then
            Log "VG ${VG} was successfully actived"
            Log "De-activate VG ${VG} again before we can restart package(s)"
            vgchange -a n ${VG} || ErrorExit "Could not de-activate VG ${VG}"
        else
            Log "De-activate VG ${VG} to be sure"
            vgchange -a n ${VG} 2>/dev/null
        fi

        i=$((i+1))
    done
        
    ShowRestartPackagesMessage   # do we care on the reply?

    # before returning remove the SUSPEND_SYNC_FLAG flag from BASEDIR
    ReleaseSuspendFlag "/tmp/$SUSPEND_SYNC_FLAG"   # call our function

    return 0
}

# ------------------------------------------------------------------------------
function InterruptReverseSync {
    ReleaseSuspendFlag "/tmp/$SUSPEND_SYNC_FLAG"
    ErrorExit "We interrupted the reversesync operation"
}

# ------------------------------------------------------------------------------
function ReleaseSuspendFlag {
    # before returning remove the SUSPEND_SYNC_FLAG flag from BASEDIR
    if [[ -f "$1" ]] && [[ -f "/tmp/do_not_remove_suspend_flag_by_reversesync" ]]; then
        rm -f "/tmp/do_not_remove_suspend_flag_by_reversesync"
        # we do not remove the suspend flag as it was already set before we started the reversesync
    else
        [[ -f "$1" ]] && rm -f "$1"
        Log "Suspend Flag SUSPEND_SYNC_FLAG removed so we can go back to \"Normal\" mode"
    fi
    return 0
}

# ------------------------------------------------------------------------------
function ShowStopPackagesWarning {
    # before starting reverse sync throw some warnings
    cat - <<EOD
    *************************************************************************
      WARNING: You must stop the serviceguard packages first 
      which are impacted by this reversesync operation!      
      To be done on the production side [$lhost] (use another tty)    
      For SAP packages cmhaltpkg (j)dbci<SID> and ers<SID>
    *************************************************************************
EOD
    askYN N "Please confirm you have stopped the packages"
    if [[ $? -eq 0 ]]; then
        # we typed enter or n
        return 1
    else
        # we typed y
        return 0
    fi
}

# ------------------------------------------------------------------------------
function ShowRestartPackagesMessage {
    cat - <<EOD
    *************************************************************************
    WARNING: You may restart the packages again on production side [$lhost]
    Please do this on another tty window and make sure the packages are in
    enable mode (use cmmodpkg -e -n node <package_name>) and then start it
    as cmrunpkg -n node <package_name>
    *************************************************************************
EOD
    askYN N "Please confirm you have started the packages"
    if [[ $? -eq 0 ]]; then
        # we typed enter or n
        return 1
    else
        # we typed y
        return 0
    fi
}

# ------------------------------------------------------------------------------
function ShowBcvMountWarning {
    # input args: PVOL_INST, SVOL_INST, VOL_GRP, DEV_GRP; output: rc 0 or 1
    PVOL_INST=$1
    SVOL_INST=$2
    VOLGRP=$3
    DGRP=$4
    VOL_GRP_s=$( ShortVGname "${VOLGRP}" )
    # serious warning to check the BCV side first
    if [[ -f "/etc/horcm${PVOL_INST}.conf" ]]; then
        # vgpludata       10.0.54.137      horcm0
        BCV_server=$( grep ^${DGRP} "/etc/horcm${PVOL_INST}.conf" | tail -1 | awk '{print $2}' )
        IsDigit $(echo $BCV_server | cut -d. -f1) && BCV_server=$(GetHostnameFromIP $BCV_server)
    else
        ErrorExit "Cannot find /etc/horcm${PVOL_INST}.conf file"
    fi
    VG=$( SetVgName ${VOL_GRP_s} ${SVOL_INST} ${DGRP} )
    cat - <<EOD
    ******************************************************************************
      WARNING: You must login (seperate tty) on the BCV server [$BCV_server]
      and verify that the device group $DGRP is not mounted anymore
      Look for "$VG" mounted devices!
    ******************************************************************************
EOD
    askYN N "Please confirm that on the BCV side the $DGRP is not mounted"
    if [[ $? -eq 0 ]]; then
        # we typed enter or n
        return 1
    else
        # we typed y
        return 0
    fi
}

# ------------------------------------------------------------------------------
function askYN
{
    # input arg1: string Y or N; arg2: string to display
    # output returns 0 if NO or 1 if YES so you can use a unary test for comparison
    # usage: askYN N "Shall we add vgexport command(s) to $(basename $SCRIPT)"
    typeset answer
    case "$1" in
        Y|y)    order="Y/n" ;;
        *)      order="y/N" ;;
    esac

    printf "$2 $order ? "
    read answer

    # record answer in the log file
    printf  "$answer \n" | tee -a $LOGFILE

    case "$1" in
        Y|y)
            if [[ "${answer}" = "n" ]] || [[ "${answer}" = "N" ]]; then
                return 0
            else
                return 1
            fi
            ;;
        *)
            if [[ "${answer}" = "y" ]] || [[ "${answer}" = "Y" ]]; then
                return 1
            else
                return 0
            fi
            ;;
    esac
}

# ------------------------------------------------------------------------------
# MAIN Program -----------------------------------------------------------------
# ------------------------------------------------------------------------------

WhoAmI		# must be root to continue

if [ "$#" = "0" ]; then
    Usage
    exit 1
fi

if [[ ! -d $dlog ]]; then
    Note "$PRGNAME ($LINENO): [$dlog] does not exist."
    print -- "     -- creating now: \c"

    mkdir -p $dlog && echo "[  OK  ]" || {
	echo "[FAILED]"
	Note "Could not create [$dlog]. Exiting now"
	MailTo "$PRGNAME: ERROR - Could not create [$dlog] on $lhost"
	exit 1
	}
fi

typeset LOGFILE=$dlog/${PRGNAME%.sh}-${STARTDATE}-${PID}.log  # will be renamed at the end


###########
# M A I N #
###########

{  # all output will now be captured in LOGFILE
echo 0 > $ERRfile   # create ERROR file with exit 0 (being optimistic)

trap "Cleanup" 1 2 3 6 11 15

# set PATH
export PATH=/bin:/usr/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/contrib/bin:/HORCM

# Argument Handling ------------------------------------------------------------
# and file specifications ------------------------------------------------------

typeset -l OPERATION

# Process any command-line options that are specified
CMD_ARGS="$*"
# -----------------------------------------------------------------------------
#                              Setting up options
# -----------------------------------------------------------------------------
while getopts ":m:c:D:Fhvd" opt; do
  case $opt in

    F) FORCE_MOUNT_PREFIX="y" ;;
    D) dlog="$OPTARG"
       is_var_empty "$dlog"
       [[ ! -d $dlog ]] && mkdir -m 755 -p $dlog
       echo "$dlog" > $MVlog2DIR # we need the read the dlog outside the block
       ;;
    d) DEBUG="echo" ;;
    h) Usage ;;
    m) mailusr="$OPTARG" 
       #[[ -z "$mailusr" ]] && mailusr=root
       ;;
    v) Revision; exit ;;
    c) CFGFILE="$OPTARG"
       is_var_empty "$CFGFILE"
       CONFIGDIR=${CFGFILE%/*}
       if [[ "$CONFIGDIR" = "$CFGFILE" ]]; then    # is the case when no path is given
           CONFIGDIR=$PWD
       fi
       ;;
    :) Note "Missing argument.\n"
       Usage ;;

  esac
done

shift $(( OPTIND - 1 ))

# mandatory option is "-c configfile", so let us check if variable is not empty
[[ -z "$CFGFILE" ]] && {
    ErrorLog "Missing argument \"-c configfile\""
    Usage
    }

OPERATION=$1

[[ -z "$OPERATION" ]] && OPERATION="validate"

IsDigit $2 && PurgeOlderThenDays=$2 || PurgeOlderThenDays=30

# ----- Validate OPERATION variable -----
ValidateOPERATION $OPERATION


# ----- define CONFIGFILE -----
CONFIGFILE=${CONFIGDIR}/$(basename $CFGFILE)
[[ -z "$CONFIGFILE" ]] && Usage

# ---- Define FAILBACK_CONFIGDIR and create it (if needed) -----
FAILBACK_CONFIGDIR=$(basename $CFGFILE)                     # e.g. dbciRPS.cfg
FAILBACK_CONFIGDIR="/var/tmp/BC/$( echo ${FAILBACK_CONFIGDIR%.*} | cut -d"_" -f1 )"   # /var/tmp/BC/dbciRPS

# locate the config file or failback config file (must have one at least)
if [[ -f $CONFIGFILE ]]; then
    :
elif [[ -f $FAILBACK_CONFIGDIR/$(basename $CFGFILE) ]]; then
    CONFIGFILE=$FAILBACK_CONFIGDIR/$(basename $CFGFILE)
else
    ErrorExit "Both Config files $CONFIGFILE or $FAILBACK_CONFIGDIR/$(basename $CFGFILE) were not found"
fi


# ----- ready to go -----
Log "$(Revision)"
Log "$PRGNAME $CMD_ARGS"
Log "PATH=${PATH}"
Log "CONFIGFILE=${CONFIGFILE}"
Log "OPERATION=${OPERATION}"
Log "MAILUSR=$mailusr"
PKGNAME=$(basename $CFGFILE)       # e.g. dbciRPS_BC1.cfg 
Log "LOGFILE=$dlog/$(echo ${PKGNAME%.*} | sed -e 's/_/-/g')-${OPERATION}-$( basename $LOGFILE )"

# BC-exec.sh should be able to handle 2 different LAYOUTs of a configuration file
# LAYOUT=1.0 only defines simple variables
# LAYOUT=2.0 works with sections [section] and contains some keywords that needs to be
# converted into arrarys and/or variables
ParseConfigFile

# ---- read in the config file ---- replaced by ParseConfigFile function
#. $CONFIGFILE || ErrorExit "Error processing $CONFIGFILE"

# Check if the variables defined in $CONFIGFILE make sense
CheckConfigFile

# ---- grab BASEDIR for the cfg and other files ----
# The FAILBACK_CONFIGDIR may be used instead of CONFIGDIR, so use $CONFIGFILE as base
BASEDIR=${CONFIGFILE%/*}

# ----- Check CONFIGDIR -----
CheckConfigDir $BASEDIR


# check if a suspend flag was set? SUSPEND_SYNC variable will also be checked
CheckSuspendSyncFlag ${BASEDIR} 	# if not empty (filename) it is set, otherwise it is empty


# do the work ------------------------------------------------------------------

case $OPERATION in
     validate) Validate        ;;
       resync) Resync          ;;
        split) Split           ;;
      extract) Extract         ;;
        mount) Mount           ;;
       umount) UnMount         ;;
    purgelogs) PurgeLogs       ;;
  reversesync) ReverseSync     ;;
            *) Usage           ;; 
esac
[[ $? -ne 0 ]] && ErrorExit "${OPERATION} failed with rc $?"
Log "${OPERATION} completed successfully."

# End processing ---------------------------------------------------------------

} 2>&1 | tee $LOGFILE 2>/dev/null 
      # note that the output of the section within brackets is piped to 
      # another process (tee); The consequence is that the exit in the
      # ErrorExit function will not exit the script but rather the first
      # part of the pipe (the bracketed code);
      # Removing the | tee and simply keeping the redirect to $LOGFILE will
      # enable the script exit in ErrorExit again. So be careful if you 
      # would ever want to change this...

mailusr=$(grep MAILUSR= $LOGFILE | tail -1 |  cut -d= -f2)
OPERATION=$(grep OPERATION= $LOGFILE | tail -1 | cut -d= -f2)
MailTo "$PRGNAME with Operation $OPERATION results"

# check if there was in ERROR in the LOGFILE and report to syslog file
grep -q ERROR $LOGFILE
if [[ $? -eq 0 ]]; then
    Text=$( grep ERROR $LOGFILE | tail -1 )
    LogToSyslog "<error> $(echo ${Text##*:})"
fi

# read the exit code from ERRfile
rc=$( cat $ERRfile )    # file with exit code (is the first line of MAIN code)
Log "Exit code $rc"

# Now we will change the name of the $LOGFILE from
# BC-exec-$STARTDATE.$PID to <pkgname>-<BC$instance>-<$operation>-BC-exec-$STARTDATE.log
NEW_LOGFILE=$( grep LOGFILE= $LOGFILE | tail -1 | cut -d= -f2 )
[[ ! -z "$NEW_LOGFILE" ]] && mv -f $LOGFILE ${NEW_LOGFILE}

if [[ -f $MVlog2DIR ]]; then
    # if dlog was overruled with -D option then we move the log now to final location
    dlog=$( cat $MVlog2DIR 2>/dev/null )
    rm -f $MVlog2DIR
    [[ -d $dlog ]] && mv -f $LOGFILE $dlog
fi

Cleanup

# EXIT
exit $rc

# ----------------------------------------------------------------------------
