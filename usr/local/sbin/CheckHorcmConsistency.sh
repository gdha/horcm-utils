#!/usr/bin/ksh
# Script: CheckHorcmConsistency.sh
#
# HORCM means Hitachi (XP) open remote copy manager
# Purpose: verify if the horcm<INST>.conf file is consitsent with LVM VGs defined

# $Revision: 1.3 $
# ----------------------------------------------------------------------------

# Parameters
############
typeset -x PRGNAME=${0##*/}
typeset -x PRGDIR=${0%/*}
typeset -x PID=$$
typeset -r platform=$(uname -s)		# Operating System name, e.g. Linux, HP-UX, SunOS
typeset -r lhost=$(uname -n)            # Local host name
typeset -r osVer=$(uname -r)            # OS Release
typeset -r model=$(uname -m)            # Model of the system
typeset -x TMP_DIR=/tmp
typeset -i KEEP=0
typeset -i VERBOSE=0
typeset -i DEBUG=0
typeset -x TYPE=""
typeset -x StatusPairs=""
typeset -x ErrCount=0
typeset -x SINGLE_DEVGRP=""
typeset -x dlog=/var/adm/log
# the LOGFILE will be overwritten each time, but its copy (tmpLOGFILE) under /var/tmp will have a timestamp
typeset -x LOGFILE=$dlog/${PRGNAME%.sh}.log
typeset -x tmpLOGFILE=/var/tmp/${PRGNAME%.sh}-$(date +%Y%m%d-%H%M%S)-${PID}.log
typeset -x mailto=""                    # empty means no mail will be send (use -m option to define a destination)

PATH=/bin:/usr/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/contrib/bin:/HORCM:/usr/local/CPR/bin:$PATH 
export PATH

#############
# Functions #
#############

# ------------------------------------------------------------------------------
function WhoAmI {
    if [ "$(id -u)" != "0" ]; then
        ErrorExit "You must be root to run script $PRGNAME" 
    fi
}

# ------------------------------------------------------------------------------
function Revision {
    typeset rev
    rev=$(awk '/Revision/ { print $3 }' $PRGDIR/$PRGNAME | head -1)
    [[ -n "$rev" ]] || rev="\"Under Development\""
    echo "$PRGNAME revision $rev"
} # Acquire revision number of the script and plug it into the log file

# ------------------------------------------------------------------------------
function IsDigit {
    expr "$1" + 1 > /dev/null 2>&1  # sets the exit to non-zero if $1 non-numeric
}

# ------------------------------------------------------------------------------
function Usage {
    cat - <<EOT
Usage: $PRGNAME [-k] [-d] [-v] [-h] [-g DevGroup] [-m mailto]

     Script $PRGNAME will inspect the HORCM instances device groups and verify if all
     disk devices are properly defined in the corresponding volume groups.

     -k keep temporary files [default no]
     -d debug will show all commands and/or functions we execute.
	This will also keep the temporary files [default no]
     -v verbose will show more information during the run [default no]
     -h help
     -g DevGroup only display information about this DevGroup instead
	of all device groups [default all]
     -m mail-recipients (quoted and comma separated)[default none]

EOT
}

# ------------------------------------------------------------------------------
function CreateTempDir {
    # the mktemp command differs between HP-UX, Linux, and other Unixes
    # so we generate a generic function for it
    # input args: $1 base directory to create temp dir in (e.g. /tmp
    #             $2 base name (we will append a RANDOM number to it)
    # output arg: directory name we generated
    typeset DIR1="$1"
    typeset DIR2="$2"
    [[ ! -d $DIR1 ]] && DIR1=/tmp  # when not existing use /tmp as default
    [[ -z "$DIR2" ]] && DIR2=${PRGNAME%.*}    # remove only the first part (before the .)
    TMP_DIR="${DIR1}/${DIR2}_${RANDOM}"
    if [[ ! -d $TMP_DIR ]]; then
	VerboseLog "Creating temporary directory $TMP_DIR"
        Debug "mkdir -m 755 $TMP_DIR"
        mkdir -m 755 $TMP_DIR || ErrorExit "Could not create temporary directory $TMP_DIR"
    fi

}

# ------------------------------------------------------------------------------
function Log {
    PREFIX="$(date "+%Y-%m-%d %H:%M:%S") LOG:"
    echo "${PREFIX} $*"
}

# ------------------------------------------------------------------------------
function Debug {
    if (( DEBUG )); then
	PREFIX="$(date "+%Y-%m-%d %H:%M:%S") DEBUG:"
        echo "${PREFIX} $*"
    fi
}

# ------------------------------------------------------------------------------
function VerboseLog {
    if (( VERBOSE )); then
        PREFIX="$(date "+%Y-%m-%d %H:%M:%S") VERBOSE:"
	echo "${PREFIX} $*"
    fi
}

# ------------------------------------------------------------------------------
function ErrorLog {
    PREFIX="$(date "+%Y-%m-%d %H:%M:%S") ERROR:"
    echo "${PREFIX} $*"
    ErrCount=$(( ErrCount + 1 ))
}

# ------------------------------------------------------------------------------
function SysLog {
    # arguments "syslog-label" "text"
    logger -t "$1" -i "$2"
}

# ------------------------------------------------------------------------------
function ErrorExit {
    ErrorLog "$*"
    ErrorLog "Exit code 1"
    exit 1
}

# ------------------------------------------------------------------------------
function MailLog {
    # args=subject line
    [[ -z "$mailto" ]] && return   # empty means no mail need to be send out
    [[ ! -f "$tmpLOGFILE" ]] && tmpLOGFILE=/dev/null
    expand "$tmpLOGFILE" | mailx -s "$*" $mailto
}

# ------------------------------------------------------------------------------
function IsPairdisplayCmdAvailable {
    type -p pairdisplay >/dev/null || ErrorExit "Command pairdisplay not found. Adjust PATH, rc $?."
    return 0
}

# ------------------------------------------------------------------------------
function AnyHorcmdRunning {
    ps -ef | grep -e horcmd_0 | grep -v grep >/dev/null || \
	ErrorExit "No horcmd daemons running! Please start it manually via horcmstart.sh command"
    return 0
}

# ------------------------------------------------------------------------------
function CheckRaidMgr {
    IsPairdisplayCmdAvailable
    AnyHorcmdRunning
}

# ------------------------------------------------------------------------------
function ShowVersionRaidManager {
    # purpose is to echo back the version og Raid Manager
    # the following check should work (as we already passed fucntion IsPairdisplayCmdAvailable)
    type -p raidqry >/dev/null ||  ErrorExit "Command raidqry not found. Adjust PATH, rc $?."
    raidqry -h | grep "^Ver" | awk '{print $2}'
}

# ------------------------------------------------------------------------------
function BCorCA {
    # input: $1 (INST), $2 (device group)
    # output: variable TYPE=BC, CA, UN(know)
    Debug "Entering function BCorCA with args $*"

    # we need to determine if this HORCM instance is a BC or CA type:
    # pairdisplay -I0 -g dbciRPS -CLI -fcxd | tail -n +2 | awk '{print $5}' |sort -u
    #65214
    #85827
    # ==> means CA as 2 serial nrs are retrieved with above example; with BC there is only 1 S/N involved
    # replaced 'tail -n +2' with 'grep -v "^Group[ \t]*"' as on multiple pages we could have issues
    Debug "pairdisplay -I${1} -g $2 -fcxd | grep -v "^Group[ \t]*" > pairdisplay.SN"
    pairdisplay -I${1} -g $2 -fcxd | grep -v "^Group[ \t]*" > "$TMP_DIR/pairdisplay.SN"

    # grab the S/N column and count it (after sort -u)
    cntSN=$( awk '{print $4}' "$TMP_DIR/pairdisplay.SN" | sort -u | wc -l )
    Debug "Count S/N in pairdisplay output (1=BC; 2=CA): $cntSN"
    # do the pairdisplay again with the proper TYPE to retrieve the correct status of the pairs
    case $cntSN in
        1) TYPE="BC"  ;;
	2) TYPE="CA"  ;;
	*) TYPE="UN"  ;;
    esac

    Debug "Detected TYPE=$TYPE (must be one of \"BC\", \"CA\" or \"UN\")"
    # TYPE variable is an exported variable (so no need to explicit return it)
}

# ------------------------------------------------------------------------------
function CheckStatusPairs {
    # input arguments: $TYPE $INST $DevGrp
    # output: file $TMP_DIR/pairdisplay.out and variable $StatusPairs (exported var)
    Debug "Entering function CheckStatusPairs with args $*"
    Debug "pairdisplay -I${1}${2} -g ${3} -CLI -fcxd | grep -v "^Group[ \t]*"  > pairdisplay.out"
    pairdisplay -I${1}${2} -g ${3} -CLI -fcxd | grep -v "^Group[ \t]*"  > "$TMP_DIR/pairdisplay.out"
    # with CA the status is on field 8 and with BC it is field 9
    if [[ "$TYPE" = "BC" ]]; then
        awk '{print $9}' "$TMP_DIR/pairdisplay.out" | sort -u > "$TMP_DIR/pair.status"
    else
        awk '{print $8}' "$TMP_DIR/pairdisplay.out" | sort -u > "$TMP_DIR/pair.status"
    fi
    count=$( cat "$TMP_DIR/pair.status" | wc -l )
    # count=1 means L/R disks have the same status; count=2 (different status)
    if (( count > 1 )) ; then
        # different status - check for "-"
	grep -q "-" "$TMP_DIR/pair.status"  && StatusPairs="ERROR"
	grep -q -e "SSUS" -e "PSUS" "$TMP_DIR/pair.status"  && StatusPairs="SPLIT"
	grep -q "SMPL" "$TMP_DIR/pair.status"  && StatusPairs="ERROR"
    else
        grep -q -e "PAIR" -e "COPY" "$TMP_DIR/pair.status"  && StatusPairs="PAIR"
    fi
    Debug "The status of the disk pairs is \"$StatusPairs\" "
}

# ------------------------------------------------------------------------------
function CreateXpInfoMap {
    # use xpinfo to create a disk map (especially needed for cdisk)
    Debug "Entering function CreateXpInfoMap with args $*"
    type -p xpinfo >/dev/null || ErrorExit "xpinfo not found. Check you PATH."
    # we add 2>/dev/null to xpinfo to get rid of "Error: No such file or directory" message
    VerboseLog "Running xpinfo - make take a while..."
    xpinfo -d  2>/dev/null | awk -F, '{
        sub ("/dev/r", "/dev/", $1);
        gsub (":", "", $5);
        print $1, tolower($5) }' | \
    sort > $TMP_DIR/xpinfo.out
    Debug "Created xpinfo.out file"
}

# ------------------------------------------------------------------------------
function CreateDiskmap {
    # purpose is to create a map of disks (disk/cdisk) with their corresponding cu_ldev number
    # input: $INST; output: disk map file $TMP_DIR/disk_culdev.out

    Debug "Entering function CreateDiskmap with args $*"
    typeset inst="$1"
    if [[ -f "$TMP_DIR/alldisk_culdev.out" ]]; then
        Debug "File alldisk_culdev.out exists -  previous CreateDiskmap call already made it"
        return
    fi

    VerboseLog "Capturing the disks with corresponding cu_ldev number for instance number $inst"
    if [[ "$osVer" = "B.11.31" ]]; then
	ioscan_args="-kfnNC"
    else
        ioscan_args="-kfnC"
    fi
    Debug "ioscan $ioscan_args disk | grep -e rdisk -e rdsk -e rcdisk | raidscan -find -fx -I${inst}"
    # output:
    # /dev/rdisk/disk60     0   F  CL1-A     0    0     85827  4000  OPEN-V
    # /dev/rdisk/disk61     0   F  CL1-A     0    1     85827  4001  OPEN-V
    # /dev/rcdisk/disk1     0   F  CL2-A     1    2     85827  4007  OPEN-V
    # becomes in file rawdisk_culdev.I${1}
    # /dev/disk/disk60 4000
    # /dev/disk/disk61 4001
    # /dev/cdisk/disk1 4007

    # raid mgr 01.24.* has no knowledge about cdisks it seems! RM 01.30 does. raidscan only display disk not cdisk
    # with older versions of RM! Therefore, alldisk_culdev map does not contain cdisks which breaks our
    # mapping later on (with lvmtab output...) => also use xpinfo then
    # we want culdev 00:0f printed as 000f and not as f
    ioscan $ioscan_args disk | grep -e rdisk -e rdsk -e rcdisk | raidscan -find -fx -I${inst} | tail -n +2 |\
    awk '{ sub ("/dev/r", "/dev/", $1); printf "%s %04s\n", tolower($1), tolower($8)}' > $TMP_DIR/alldisk_culdev_tmp.I${inst}

    VERSIONRM=$(ShowVersionRaidManager)
    SUBVERRM=$(echo $VERSIONRM | cut -d. -f2)    # e.g. 24
    Debug "Raid Manager sub-version is $SUBVERRM"
    IsDigit $SUBVERRM || SUBVERRM=0   # make sure we are dealing with a digit
    if (( $SUBVERRM < 30 )); then
         Debug "Raid Manager version $VERSIONRM has no knowledge about cluster disks"
         Debug "We will use xpinfo to find the cdisks - if any"
         [[ ! -f "$TMP_DIR/xpinfo.out" ]] && CreateXpInfoMap  # we need to do this only once
    fi 

    if [[ -f "$TMP_DIR/xpinfo.out" ]]; then
        # we need to merge the $TMP_DIR/alldisk_culdev_tmp.I${inst}
        Debug "Merge the raidscan and xpinfo output (to get the cdisk info)"
        cat "$TMP_DIR/alldisk_culdev_tmp.I${inst}" "$TMP_DIR/xpinfo.out" | sort -u > "$TMP_DIR/alldisk_culdev_tmp.tmp"
        mv "$TMP_DIR/alldisk_culdev_tmp.tmp" "$TMP_DIR/alldisk_culdev_tmp.I${inst}"
    fi

    VerboseLog "Create one line per \"cdisk disk culdev\" or \"disk culdev\""
    awk '{print $2}' $TMP_DIR/alldisk_culdev_tmp.I${inst} | sort -u | while read i
    do
	# per culdev number map all corresponding devices on "one" line using some magic awk/paste
	echo $i $(awk -v culdev=$i '$2 == culdev {print $1}' $TMP_DIR/alldisk_culdev_tmp.I${inst} | paste -d " " - - ) \
	>> $TMP_DIR/alldisk_culdev.out
	# output:
	# 4004 /dev/disk/disk67 
	# 4006 /dev/cdisk/disk5 /dev/disk/disk69 
        Debug "Adding disk(s) of culdev=$i to map file alldisk_culdev.out"
    done
    [[ ! -s "$TMP_DIR/alldisk_culdev.out" ]] && ErrorExit "Empty disk map file $TMP_DIR/alldisk_culdev.out"
    Debug "Created file alldisk_culdev.out containing full list of CU:LDEV to (c)disks mapping"
    rm -f $TMP_DIR/alldisk_culdev_tmp.I${inst}
    return 0
}

# ------------------------------------------------------------------------------
function CreateDiskmapLinux {
    # input: $INST; output: disk map file $TMP_DIR/disk_culdev.I${inst}
    Debug "Entering function CreateDiskmapLinux with args $*"
    typeset inst="$1"
    VerboseLog "Capturing the disks with corresponding cu_ldev number for instance number $inst"

    # #-> ls /dev/sd* | raidscan -find -fx -I00
    # DEVICE_FILE         UID  S/F PORT   TARG  LUN    SERIAL  LDEV  PRODUCT_ID
    # /dev/sdaa             0   F  CL2-B     0  127     65214  40B9  OPEN-V
    # /dev/sdab             0   F  CL2-B     0  128     65214  40BA  OPEN-V

    Debug "ls /dev/sd* | raidscan -find -fx -I${inst} | tail -n +2"
    VerboseLog "Busy Processing using raidscan..."
    ls /dev/sd* | raidscan -find -fx -I${inst} | tail -n +2 | \
    awk '{print tolower($8), $1}' | sort -u > $TMP_DIR/alldisk_culdev_tmp.I${inst}
    # output is typically:
    # 40b1 /dev/sdcf
    # 40b1 /dev/sdes
    # 40b1 /dev/sdhf
    # 40b1 /dev/sds
    # we want to combine the 4 paths on one line
    awk '{print $1}' $TMP_DIR/alldisk_culdev_tmp.I${inst} | sort -u | while read i
    do
        echo $i $(awk -v culdev=$i '$1 == culdev {print $2}' $TMP_DIR/alldisk_culdev_tmp.I${inst} |\
	paste -d " " - - - - ) >> $TMP_DIR/alldisk_culdev.I${inst}
        Debug "Adding disk(s) of culdev=$i to map file alldisk_culdev.I${inst}"
    done
    [[ ! -s $TMP_DIR/alldisk_culdev.I${inst} ]] && ErrorExit "Empty disk map file $TMP_DIR/alldisk_culdev.I${inst}"
    rm -f $TMP_DIR/alldisk_culdev_tmp.I${inst}
    return 0
}

# ------------------------------------------------------------------------------
function CreateVGmap {
    # purpose is to make a map of VGs known on this system
    # all cdisk devices should be translated to disk devices followed by CU_LDEV number
    # input: none; output: some map file(s)
    Debug "Entering function CreateVGmap with args $*"
    VerboseLog "Capturing the Volume groups with their devices"
    # read lvmtab to capture disks in LVM 1
    Debug "strings /etc/lvmtab | awk ..."
    strings /etc/lvmtab | awk '
       /dev\/vg/ {vg=$1}
	  /dev\/d.*sk/ {print $1, vg}
	  /dev\/cd.*sk/ {print $1, vg}' >  $TMP_DIR/lvmtab.out
    # read lvmtab_p to capture disks in LVM 2 or higher
    if [[ -r /etc/lvmtab_p ]]; then
	Debug "strings /etc/lvmtab_p | awk ..."
        strings /etc/lvmtab_p | awk '
	   /dev\/vg/ {vg=$1}
           /dev\/d.*sk/ {print $1, vg}
	   /dev\/cd.*sk/ {print $1, vg}' >>  $TMP_DIR/lvmtab.out
    fi
}

# ------------------------------------------------------------------------------
function CreateVGmapLinux {
    Debug "Entering function CreateVGmapLinux with args $*"
    VerboseLog "Capturing the Volume groups with their devices"
    Debug "pvs | tail -n +2 | awk '{print \$1, \$2}'"
    pvs | tail -n +2 | awk '{print $1, $2}' | grep -v -e lvm2 -e vg00 | sort > $TMP_DIR/lvmtab.out
}

# ------------------------------------------------------------------------------
function SaveCuLdevDevGroup {
    # input arguments: "${TYPE}" "${INST}" "${DevGrp}"
    # output: file $TMP_DIR/culdev.${devgrp} and paired_culdev.I${INST}
    Debug "Entering function SaveCuLdevDevGroup with args $*"
    typeset Imode="${1}${2}"     # Instance mode [HORC (BC) or MRCF (CA)]
    typeset inst="$2"
    typeset TYPE="$1"
    typeset devgrp="$3"    # Device group to dig into
    VerboseLog "Save the cu:ldev numbers of the disks into culdev.${devgrp}"
    Debug "pairdisplay -l -I${Imode} -g ${devgrp} -CLI -fcxd | tail -n +2 | sort -k7,7 > pairdisplay.${devgrp}"
    # sort of culdev column
    pairdisplay -l -I${Imode} -g ${devgrp} -CLI -fcxd | tail -n +2 | sort -k7,7 > $TMP_DIR/pairdisplay.${devgrp}
    # output is like for BC:
    # vgInterfaces    40:1f_40:47 L   disk80         1  85827  401f P-VOL PSUS    99    4047 W
    # or for CA:
    # ers06RPS        40:1c_41:07 L   disk84         85827  401c P-VOL PAIR NEVER    100  4107 -
    if [[ "$TYPE" = "BC" ]]; then
        awk '{ printf "%04s\n", tolower($7) }' < $TMP_DIR/pairdisplay.${devgrp} > $TMP_DIR/culdev.${devgrp}
        # output: CU_LDEV-nr
        # 401f 
    else
        awk '{ printf "%04s\n", tolower($6) }' < $TMP_DIR/pairdisplay.${devgrp} > $TMP_DIR/culdev.${devgrp}
    fi
    # $TMP_DIR/paired_culdev.I${inst} will be used to verify horcmperm${inst}.conf file
    cat "$TMP_DIR/culdev.${devgrp}" >> "$TMP_DIR/paired_culdev.I${inst}"
    # make a copy according type BC/CA $inst
    cp "$TMP_DIR/paired_culdev.I${inst}" "$TMP_DIR/paired_culdev.${TYPE}.${inst}"
}

# ------------------------------------------------------------------------------
function MapDevGroupInLvmtab {
    # input arguments: "${TYPE}" "${INST}" "${DevGrp}" ; and files culdev.${devgrp} and alldisk_culdev.out
    # output: $TMP_DIR/lvmtab.${devgrp}
    Debug "Entering function MapDevGroupInLvmtab with args $*"
    typeset horcm_type="$1"
    typeset inst="$2"
    typeset devgrp="$3" 
    VerboseLog "Map all culdev numbers of ${devgrp} with disks belonging to ${inst}"
    [[ ! -f "$TMP_DIR/culdev.${devgrp}" ]] && ErrorExit "File not found: culdev.${devgrp}"
    [[ ! -f "$TMP_DIR/alldisk_culdev.out" ]] && ErrorExit "File not found: alldisk_culdev.out"

    # Input file $TMP_DIR/culdev.${devgrp} and $TMP_DIR/alldisk_culdev.out
    Debug "join -a 1 culdev.${devgrp} alldisk_culdev.out > culdev_disks.${devgrp}"
    join -a 1 $TMP_DIR/culdev.${devgrp} $TMP_DIR/alldisk_culdev.out > $TMP_DIR/culdev_disks.${devgrp}
    # output is like:
    # 4007 /dev/cdisk/disk1 /dev/disk/disk62
    # 4045 /dev/disk/disk106
    # make sure that disk1 and disk2 are empty
    unset disk1 disk2
    cat $TMP_DIR/culdev_disks.${devgrp} | while read culdev disk1 disk2
    do
	Debug "Processing line $culdev with disk $disk1 and maybe disk $disk2"
        if [[ -z "$culdev" ]]; then
	    ErrorLog "culdev not found in $TMP_DIR/culdev_disks.${devgrp}"
	    break
        elif [[ "$culdev" = "-" ]]; then
            ErrorLog "No disks found on this side for device group ${devgrp} (with ${TYPE}${INST})"
	    break
	fi
	[[ -z "$disk1"  ]] && ErrorLog "Must have at least 1 disk defined in $TMP_DIR/culdev_disks.${devgrp}"
	# input file $TMP_DIR/lvmtab.out containing disks with corresponding Volume Group
	# output: $TMP_DIR/lvmtab.${horcm_type}${inst}.${devgrp} like:
	# culdev VG
	grep -q "^${disk1} " $TMP_DIR/lvmtab.out
	if [[ $? -eq 0 ]]; then
            # /dev/cdisk/disk131 /dev/vg_dbcipj5 (lvmtab.out)
            Debug "$culdev $( grep "^${disk1} " $TMP_DIR/lvmtab.out | awk '{print $2}' )"
            echo "$culdev $( grep "^${disk1} " $TMP_DIR/lvmtab.out | awk '{print $2}' )" >> $TMP_DIR/lvmtab.unsorted.${horcm_type}${inst}.${devgrp}
	fi
	if [[ ! -z "$disk2" ]]; then
            grep -q "^${disk2} " $TMP_DIR/lvmtab.out
	    if [[ $? -eq 0 ]]; then
                Debug "$culdev $( grep "^${disk2} " $TMP_DIR/lvmtab.out | awk '{print $2}' )"
                echo "$culdev $( grep "^${disk2} " $TMP_DIR/lvmtab.out | awk '{print $2}' )" >> $TMP_DIR/lvmtab.unsorted.${horcm_type}${inst}.${devgrp}
	    fi
	fi
    done
    if [[ -f "$TMP_DIR/lvmtab.unsorted.${horcm_type}${inst}.${devgrp}" ]]; then
	Debug "sort -u < lvmtab.unsorted.${horcm_type}${inst}.${devgrp} > lvmtab.${horcm_type}${inst}.${devgrp}"
        sort -u < $TMP_DIR/lvmtab.unsorted.${horcm_type}${inst}.${devgrp} > $TMP_DIR/lvmtab.${horcm_type}${inst}.${devgrp}
        rm -f $TMP_DIR/lvmtab.unsorted.${horcm_type}${inst}.${devgrp}
	VerboseLog "Created file lvmtab.${horcm_type}${inst}.${devgrp} containing culdev linked to volume group for device group ${devgrp}"
    else
	Debug "File lvmtab.unsorted.${devgrp} not found - cannot create lvmtab.${horcm_type}${inst}.${devgrp}"
        VerboseLog "Could not map any culdev devices to a volume group for device group ${devgrp} [BCV side?]"
        # on the BCV side it is unlikely the lvmtab entries exist for this device group
	# we can try to reverse engineer the lvmconf entries of VGs imported (once) using BC scripts?
	# However, success is not guaranteed
        RetrieveDisksAndVGFromLvmconf "$horcm_type" "$inst" "$devgrp"
    fi
    # the $TMP_DIR/lvmtab.${horcm_type}${inst}.${devgrp} contains:
    # 4006 /dev/vgdbRPS
    # 4007 /dev/vgdbRPS
    # 4045 /dev/vgdbRPS
}

# ------------------------------------------------------------------------------
function RetrieveDisksAndVGFromLvmconf {
    # input arguments: "$horcm_type" "$inst" "$devgrp"
    # output file: lvmtab.${horcm_type}${inst}.${devgrp} (maybe)
    Debug "Entering function RetrieveDisksAndVGFromLvmconf with args $*"
    typeset horcm_type="$1"
    typeset inst="$2"
    typeset devgrp="$3"
    [[ ! -d /etc/lvmconf ]] && return 0    # then not HP-UX??
    if [[ -f "/etc/lvmconf/vg${horcm_type}${inst}_${devgrp}.conf" ]]; then
	# consider us as lucky - we found a matching VG created following the BC-exec.sh naming convention
	VG=$(strings "/etc/lvmconf/vg${horcm_type}${inst}_${devgrp}.conf" | grep CONFIG02 | sed -e 's/CONFIG02//' )
	strings "/etc/lvmconf/vg${horcm_type}${inst}_${devgrp}.conf" | grep disk | while read dskdev
	do
            culdev=$(grep "$dskdev" "$TMP_DIR/culdev_disks.${devgrp}" | awk '{print $1}')
	    echo "$culdev $VG" >> "$TMP_DIR/lvmtab.${horcm_type}${inst}.${devgrp}"
	done
        return 0
    fi
}

# ------------------------------------------------------------------------------
function MapDevMapperToCuLdevInLvmtabLinux {
    # input arguments: "${TYPE}" "${INST}" "${DevGrp}"
    typeset inst="$2"
    Debug "Entering function MapDevMapperToCuLdevInLvmtabLinux with args $*"
    VerboseLog "Find the according culdev of /dev/mapper/devices in lvmtab.out"
    # input file lvmtab.out contains: /dev/mapper/mpathd vgpludata
    # output: file $TMP_DIR/lvmtab.culdev
    [[ ! -f $TMP_DIR/lvmtab.out ]] && ErrorExit "File not found: lvmtab.out"
    [[ ! -f $TMP_DIR/alldisk_culdev.I${inst} ]] && ErrorExit "File not found: alldisk_culdev.I${inst}"

    cat $TMP_DIR/lvmtab.out | while read devmapdev volgrp
    do
	##-> multipath -l /dev/mapper/mpathd
	#mpathd (360060e8006febe000000febe000040b1) dm-7 HP,OPEN-V
	#size=75G features='1 queue_if_no_path' hwhandler='0' wp=rw
	#`-+- policy='service-time 0' prio=0 status=active
	#  |- 4:0:2:17 sds  65:32   active undef running
	#    |- 4:0:3:17 sdcf 69:48   active undef running
	#      |- 5:0:2:17 sdes 129:64  active undef running
	#	`- 5:0:3:17 sdhf 133:80  active undef running

        dev=$( multipath -l $devmapdev | tail -n 1 | awk '{print $3}' )
	[[ -z "$dev" ]] && continue
	Debug "Mapped device mapper $devmapdev to a disk device $dev"
	# now we need file $TMP_DIR/alldisk_culdev.I${inst} which contains entries like:
	# 40b1 /dev/sdcf /dev/sdes /dev/sdhf /dev/sds 
	# we grab the culdev and write it into a file $TMP_DIR/lvmtab.culdev.unsorted
	grep -e "${dev}$" -e "${dev} " $TMP_DIR/alldisk_culdev.I${inst} | while read culdev junk
	do
	    Debug "Mapped CU:LDEV $culdev to Volume Group $volgrp"
            echo "$culdev $volgrp" >> $TMP_DIR/lvmtab.culdev.unsorted
	done
    done
    if [[ -f "$TMP_DIR/lvmtab.culdev.unsorted" ]]; then
	Debug "sort -u < lvmtab.culdev.unsorted > lvmtab.culdev"
        sort -u < $TMP_DIR/lvmtab.culdev.unsorted > $TMP_DIR/lvmtab.culdev
        rm -f $TMP_DIR/lvmtab.culdev.unsorted
        VerboseLog "Created file lvmtab.culdev which maps culdev to volume groups"
    else
	Debug "Required file lvmtab.culdev.unsorted not found - cannot create lvmtab.culdev"
    fi
}

# ------------------------------------------------------------------------------
function MapDevGroupInLvmtabLinux {
    # input arguments: "${TYPE}" "${INST}" "${DevGrp}"
    typeset horcm_type="$1"
    typeset inst="$2"
    typeset devgrp="$3"
    Debug "Entering function MapDevGroupInLvmtabLinux with args $*"
    VerboseLog "Find the according culdev to device group $devgrp"
    [[ ! -f "$TMP_DIR/culdev.${devgrp}" ]] && ErrorExit "File not found: culdev.${devgrp}"
    [[ ! -f "$TMP_DIR/lvmtab.culdev"    ]] && ErrorExit "File not found: lvmtab.culdev"
    Debug "Join culdev.${devgrp} and lvmtab.culdev into lvmtab.${horcm_type}${inst}.${devgrp}"
    join -a 1 "$TMP_DIR/culdev.${devgrp}" "$TMP_DIR/lvmtab.culdev" | sort > "$TMP_DIR/lvmtab.${horcm_type}${inst}.${devgrp}"
    VerboseLog "Created file lvmtab.${horcm_type}${inst}.${devgrp} which maps culdev to volume group of device group ${devgrp}"
}

# ------------------------------------------------------------------------------
function CmpVolGrpWithDevGroup {
    # input arguments: "${TYPE}" "${INST}" "${DevGrp}"
    typeset horcm_type="$1"
    typeset inst="$2"
    typeset devgrp="$3"
    Debug "Entering function CmpVolGrpWithDevGroup with args $*"
    if [[ ! -f "$TMP_DIR/lvmtab.${horcm_type}${inst}.${devgrp}" ]]; then
        ErrorLog "File not found: lvmtab.${horcm_type}${inst}.${devgrp}"
	ErrorLog "No volume group found for device group ${devgrp}"
	return
    fi

    [[ ! -f "$TMP_DIR/pairdisplay.${devgrp}" ]]  && ErrorExit "File not found: pairdisplay.${devgrp}"
    unset VG
    VG=$( awk '{print $2}' "$TMP_DIR/lvmtab.${horcm_type}${inst}.${devgrp}" | sort -u | tr '\n'  ' ' ) # should only be 1 VG with BC
    VerboseLog "Compare the devices in Device Group $devgrp with the corresponding Volume Group $VG"

    Debug "Compare pairdisplay.${devgrp} output with disks in volume group ($VG) of device group ${devgrp} [type $horcm_type]"
    cntpair=$( wc -l "$TMP_DIR/pairdisplay.${devgrp}" | awk '{print $1}' )
    cntpvs=$( wc -l  "$TMP_DIR/lvmtab.${horcm_type}${inst}.${devgrp}" | awk '{print $1}' )
    if [[ "$StatusPairs" = "ERROR" ]]; then
	SysLog "horcm-${TYPE}${inst}" "Device group $devgrp with VG $VG has status $StatusPairs"
        ErrorLog "Device group $devgrp (${TYPE}${inst}) with VG $VG is in trouble! Inspect the setup in /etc/horcm${inst}.conf"
    elif (( cntpair != cntpvs )); then
	SysLog "horcm-${TYPE}${inst}" "Device group ${devgrp} contains not the same amount of disks as VG $VG"
        ErrorLog "Pairdisplay of device group ${devgrp} contains not the same amount of disks as VG $VG [NOK]"
    else
        Log "Pairdisplay of device group ${devgrp} contains the same amount of disks as VG $VG [OK]"
    fi

}

# ------------------------------------------------------------------------------
function ConvertHorcmPermFileToCuLdev {
    # input arguments: "${INST}"
    # input file: /etc/horcmperm${inst}.conf $TMP_DIR/alldisk_culdev.out
    # output file: horcmperm${inst}.culdev
    typeset inst="$1"

    Debug "Entering function ConvertHorcmPermFileToCuLdev with args $*"
    [[ ! -f "/etc/horcmperm${inst}.conf" ]] && ErrorExit "File not found: /etc/horcmperm${inst}.conf"

    Debug "Transform rdevices to devices (/etc/horcmperm${inst}.conf => horcmperm_dev.I${inst})"
    # make sure we remove empty lines as well (awk 'NF > 0')
    grep -v "^\#" "/etc/horcmperm${inst}.conf"  | awk 'NF > 0' | while read dev
    do
        echo "/dev/${dev#/dev/r}" 
    done  > "$TMP_DIR/horcmperm_dev.I${inst}"

    # replace the devices with their corresponding culdev numbers
    Debug "Replace the devices with their corresponding culdev numbers alldisk_culdev.out => horcmperm${inst}.culdev"
    cat "$TMP_DIR/horcmperm_dev.I${inst}" | while read dev
    do
        Debug "horcmperm: grep -e ${dev}  alldisk_culdev.out"
        grep -e "${dev} " -e "${dev}$" "$TMP_DIR/alldisk_culdev.out" | \
	awk '{print $1}' >> "$TMP_DIR/horcmperm_culdev.I${inst}.unsorted"
    done

    if [[ -f "$TMP_DIR/horcmperm_culdev.I${inst}.unsorted" ]]; then
        sort -u < "$TMP_DIR/horcmperm_culdev.I${inst}.unsorted" > "$TMP_DIR/horcmperm_culdev.I${inst}"
	rm -f "$TMP_DIR/horcmperm_culdev.I${inst}.unsorted"
	VerboseLog "Created file horcmperm_culdev.I${inst}"
    fi
}

# ------------------------------------------------------------------------------
function CompareHorcmPermFileWithLvmtab {
    # input arguments "${INST}"
    typeset inst="$1"

    Debug "Entering function CompareHorcmPermFileWithLvmtab with args $*"
    [[ ! -f "$TMP_DIR/horcmperm_culdev.I${inst}" ]] && ErrorExit "File not found: horcmperm_culdev.I${inst}"

    Debug "cat lvmtab.??${inst}.* | sort >  lvmtab.I${inst}"
    cat $TMP_DIR/lvmtab.??${inst}.* | sort > "$TMP_DIR/lvmtab.I${inst}"

    Debug "join -a 1  horcmperm_culdev.I${inst} lvmtab.I${inst} > horcmperm_lvmtab.I${inst}"
    join -a 1 "$TMP_DIR/horcmperm_culdev.I${inst}" "$TMP_DIR/lvmtab.I${inst}" \
    > "$TMP_DIR/horcmperm_lvmtab.I${inst}"

    cmp -s "$TMP_DIR/lvmtab.I${inst}" "$TMP_DIR/horcmperm_lvmtab.I${inst}"
    if [[ $? -eq 0 ]]; then
        Log "Disks in horcmperm${inst}.conf matches with disks listed with instance ${inst} [OK]"
    else
        ErrorLog "Disks in horcmperm${inst}.conf do not match disks listed with instance ${inst} [NOK]"
	sdiff -s  "$TMP_DIR/lvmtab.I${inst}" "$TMP_DIR/horcmperm_lvmtab.I${inst}"
	SysLog "horcmperm" "Check the /etc/horcmperm${inst}.conf file and $LOGFILE for more details"
    fi
}

# ------------------------------------------------------------------------------
function CompareHorcmPermFileWithPairedDisks {
    # input arguments "${INST}"
    typeset inst="$1"

    Debug "Entering function CompareHorcmPermFileWithPairedDisks with args $*"
    [[ ! -f "$TMP_DIR/horcmperm_culdev.I${inst}" ]] && ErrorExit "File not found: horcmperm_culdev.I${inst}"
    [[ ! -f "$TMP_DIR/paired_culdev.I${inst}"    ]] && ErrorExit "File not found: paired_culdev.I${inst}"

    # comment: do not use $(ls "$TMP_DIR/paired_culdev.*.${inst}") otherwise you get an error
    BCorCAtype=$( ls $TMP_DIR/paired_culdev.*.${inst} | cut -d. -f2 ) # should only be 1 file
    case "$BCorCAtype" in
        BC|CA) TYPE="$BCorCAtype" ;;
	*)     TYPE="UN" ;;
    esac
    sort < "$TMP_DIR/paired_culdev.I${inst}" > "$TMP_DIR/paired_culdev.I${inst}.sorted"
    mv -f "$TMP_DIR/paired_culdev.I${inst}.sorted" "$TMP_DIR/paired_culdev.I${inst}"

    Debug "cmp -s $TMP_DIR/horcmperm_culdev.I${inst} $TMP_DIR/paired_culdev.I${inst}"
    cmp -s "$TMP_DIR/horcmperm_culdev.I${inst}" "$TMP_DIR/paired_culdev.I${inst}"
    if [[ $? -eq 0 ]]; then
        Log "Disks in horcmperm${inst}.conf (type $TYPE) matches with disks listed with instance ${inst} [OK]"
    else
        ErrorLog "Disks in horcmperm${inst}.conf (type $TYPE) do not match disks listed with instance ${inst} [NOK]"
        # we would like to parse the output to get the disk names instead of culdev names
        sdiff -s  "$TMP_DIR/horcmperm_culdev.I${inst}" "$TMP_DIR/paired_culdev.I${inst}" | \
         grep -e '<' -e '>' | sed -e 's/>//' -e 's/<//' | awk '{print $1}' | while read culdev
         do
             ErrorLog "Disk cu:ldev $(grep $culdev $TMP_DIR/alldisk_culdev.out) not defined consistently"
         done
        SysLog "horcmperm" "Check the /etc/horcmperm${inst}.conf file and $LOGFILE for more details"
    fi
}

# ------------------------------------------------------------------------------

###############
### M A I N ###
###############

[[ ! -d $dlog ]] &&  mkdir -p -m 755 "$dlog"

WhoAmI

{  # all output will now be captured in LOGFILE

# Process any command-line options that are specified
CMD_ARGS="$*"

while getopts ":khdvg:m:" opt; do
    case $opt in
        k) KEEP=1 ;;
        g) SINGLE_DEVGRP="$OPTARG" ;;
        d) DEBUG=1; VERBOSE=1 ;;
        v) VERBOSE=1 ;;
        m) mailto="$OPTARG" ;;
	h) Usage ; exit 0 ;;
        *) printf "ERROR: Invalid argument: ${OPTARG}.\n\n"
	   Usage ; exit 1 ;;
    esac
done
shift $(( OPTIND - 1 ))

# ----- ready to go -----
Log "$(Revision)"
Log "Started as: ${PRGDIR}/${PRGNAME} $CMD_ARGS"
VerboseLog "LOGFILE=$LOGFILE"
VerboseLog "tmpLOGFILE=$tmpLOGFILE"
if [[ ! -z "$mailto" ]]; then
    Log "mailto=$mailto"
fi

# before starting the HORCM configuration in-depth analysis - check if HORCM is installed
CheckRaidMgr

# version of RM
VERSIONRM=$(ShowVersionRaidManager)
VerboseLog "Raid Manager version is $VERSIONRM"

# create a temporary directory which is easier to clean up at the end
CreateTempDir
# grab the content of the lvmtab files in general (lvmtab.out)
case $platform in
    HP-UX) CreateVGmap
           ;;
    Linux) CreateVGmapLinux
           ;;
    *)     ErrorExit "Platform $platform not yet supported." ;;
esac

# loop over the running horcmd daemons
for INST in $( ps -ef | grep horcmd_ | grep -v grep | cut -d"_" -f2 | awk '{printf "%d\n",$0}' )
do
    # Loop over all running horcm daemons (can be BC or CA - we do not know at this moment)
    Log " === Horcm daemon active with instance nummer $INST ==="

    [[ -f /etc/horcm${INST}.conf ]] && VerboseLog "Found /etc/horcm${INST}.conf - analyzing..."

    # per instance we create a disk map (cdisk/disk culdev) - alldisk_culdev.out
    case $platform in
	HP-UX) CreateDiskmap $INST ;;
	Linux) CreateDiskmapLinux $INST ;;
    esac

    for DevGrp in `awk '/HORCM_INST/ {section=1}
        section == 1 && $1 != "HORCM_INST" && $1 !~ "^#.*" {print $1}' /etc/horcm${INST}.conf | sort -u`
        do
	  # check option -g (empty means check all device groups)
	  if [[ ! -z "$SINGLE_DEVGRP" ]]; then
	      grep -q "^${SINGLE_DEVGRP}" /etc/horcm${INST}.conf
	      if (( $? > 0 )); then
		  ErrorLog "Device group $SINGLE_DEVGRP not found in /etc/horcm${INST}.conf"
		  break
              fi
          fi

	  if [[ -z "$SINGLE_DEVGRP"  || "$DevGrp" = "$SINGLE_DEVGRP" ]]; then
	    VerboseLog "*** Inspect device group $DevGrp defined with HORCM instance $INST ***"
	    # BCorCA function sets the proper TYPE (BC, CA or UN)
            BCorCA "$INST" "$DevGrp"
	    if [[ "$TYPE" = "UN" ]]; then
	        ErrorLog "Device group $DevGrp with INST ($INST) is not configured for HORCM usage."
            fi

	    # Check the status of the PAIR disks (define variable StatusPairs)
	    Debug "CheckStatusPairs $TYPE $INST $DevGrp"
	    CheckStatusPairs "$TYPE" "$INST" "$DevGrp"
            if [[ "$StatusPairs" = "ERROR" ]]; then
		# valid status are "PAIR" or "SPLIT"
	        ErrorLog "Device group $DevGrp with INST ($INST) has mode $TYPE, but status is $StatusPairs - please investigate."
		SysLog "horcm-${TYPE}${INST}" "Device group $DevGrp has status $StatusPairs"
		cat "$TMP_DIR/pairdisplay.out"
		echo "============================================================================"
            fi
            if [[ "$TYPE" = "CA" ]] && [[ "$StatusPairs" = "SPLIT" ]]; then
                # CA should always be paired
		ErrorLog "Device group $DevGrp with INST ($INST) has mode $TYPE, but status is $StatusPairs - should be PAIR"
		cat "$TMP_DIR/pairdisplay.out"
		echo "============================================================================"
	    else
		# TYPE=CA or BC
		VerboseLog "Device group $DevGrp with INST ($INST) is defined as $TYPE (status: $StatusPairs)"
		# create disk map per device group - disk_culdev.$DevGrp
                SaveCuLdevDevGroup "${TYPE}" "${INST}" "${DevGrp}"

		case $platform in
                    HP-UX) MapDevGroupInLvmtab "${TYPE}" "${INST}" "${DevGrp}"
			   CmpVolGrpWithDevGroup "${TYPE}" "${INST}" "${DevGrp}"
			   ;;
		    Linux) if [[ ! -f "$TMP_DIR/lvmtab.culdev" ]]; then
			       # we only need to convert lvmtab.out once (if more VGs per DevGrps are defined)
			       MapDevMapperToCuLdevInLvmtabLinux "${TYPE}" "${INST}" "${DevGrp}"
                           fi
			   MapDevGroupInLvmtabLinux "${TYPE}" "${INST}" "${DevGrp}"
			   CmpVolGrpWithDevGroup "${TYPE}" "${INST}" "${DevGrp}"
			   ;;
		esac

	    fi ## [[ "$TYPE" = "CA" ]] && [[ "$StatusPairs" = "SPLIT" ]]
          fi ## [[ -z "$SINGLE_DEVGRP" || "$DevGrp" = "$SINGLE_DEVGRP" ]]

        done  # end of DevGrp

    # check /etc/horcmperm${INST}.conf file
    if [[ -f "/etc/horcmperm${INST}.conf" ]]; then
	# horcm disk permission file (contain raw devices)
	VerboseLog "Found /etc/horcmperm${INST}.conf file - analyzing..."
        ConvertHorcmPermFileToCuLdev "${INST}"
        #CompareHorcmPermFileWithLvmtab "${INST}"
        CompareHorcmPermFileWithPairedDisks "${INST}"
    fi

done  # end of INST

# cleanup temporary directory (not when -d [debug] option was defined)
if (( DEBUG )); then
    Debug "TMP_DIR=$TMP_DIR is not removed [do it manually after you are done with it]."
    Debug "To clean up temporary files execute: rm -rf $TMP_DIR"
elif (( KEEP )); then
    Log "To clean up temporary files execute manually: rm -rf $TMP_DIR"
else
    VerboseLog "Remove all temporary files [executed: rm -rf $TMP_DIR]"
    rm -rf $TMP_DIR
fi
Log "Error count: $ErrCount"

# End processing ---------------------------------------------------------------

} 2>&1 | tee $LOGFILE 2>/dev/null
      # note that the output of the section within brackets is piped to
      # another process (tee); The consequence is that the exit in the
      # ErrorExit function will not exit the script but rather the first
      # part of the pipe (the bracketed code);
      # Removing the | tee and simply keeping the redirect to $LOGFILE will
      # enable the script exit in ErrorExit again. So be careful if you
      # would ever want to change this...

# the logfile in /var/tmp/ contains timestamp, but will be cleaned up automatically after 30 days by cron job
cp -p "$LOGFILE" "$tmpLOGFILE"
echo "See logfiles: $LOGFILE and $tmpLOGFILE"

# send only mail if mailto variable has been set (with the -m option as default is empty)
mailto=$(grep mailto= $LOGFILE | head -1 | cut -d= -f 2)
MailLog "$(hostname) - CheckHorcmConsistency report"

exit 0

# ----------------------------------------------------------------------------
