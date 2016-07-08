#!/usr/bin/ksh
#
# This script will perform several pairdisplay commands for each
# device group defined in the horcm-instance.
#
# $Revision: 1.7 $
# ----------------------------------------------------------------------------

# DEBUGGING
#DEBUG="echo"    # empty string means the real stuff
DEBUG=""

# ------------------------------------------------------------------------------
# Paramters --------------------------------------------------------------------
# ------------------------------------------------------------------------------

typeset -x PRGNAME=${0##*/}
typeset -x PRGDIR=${0%/*}
typeset -r platform=$(uname -s)        # Operating System name, e.g. linux, HP-UX, SunOS
typeset -r lhost=$(uname -n)            # Local host name
typeset -r osVer=$(uname -r)            # OS Release
typeset model=$(uname -m)               # Model of the system

[[ $PRGDIR = /* ]] || PRGDIR=$(pwd) # Acquire absolute path to the script

# ------------------------------------------------------------------------------
# Functions --------------------------------------------------------------------
# ------------------------------------------------------------------------------

function Usage 
{
cat - <<EOT
Usage: $0 [-g devicegroup] [-c] HORCM-instance
       HORCM-instance: The type and number of the horcm-instance.
                       Needs to be in this format XX9.
               Where XX can be CA or BC and 9 is to be replaced
               with the horcm instance number.

       -g devicegroup
          use -g devicegroup to limit the output to only a specific device group
       -c
          Use the -c flag to perform a consistency check. Instead of showing the 
          pairdisplay output, only a count of the number of PAIRS that have the 
          same status will be given.
          For CA this includes the fields PVOL/SVOL, Status, Fence and %;
          For BC the fields are PVOL/SVOL and Status;

Examples: 

$0 -g jdbciNPS -c CA0
jdbciNPS --------------------------------------------------------------
  3 devices are P-VOL PAIR NEVER 100
  3 devices are S-VOL PAIR NEVER 100
this shows that the CA group jdbciNPS consists of 3 PAIRS and all have 
status PAIR, Fence-level NEVER and are 100% synchronized.

$0 -g vgdbNPS -c BC5
vgdbNPS --------------------------------------------------------------
  2 devices are P-VOL PAIR
  2 devices are S-VOL PAIR
this shows that the BC group vgdbNPS consists of 2 PAIRS in PAIR state.

EOT
exit 1
}

# ------------------------------------------------------------------------------
function WhoAmI {
    if [ "$(whoami)" != "root" ]; then
        echo "$(whoami) - You must be root to run script $PRGNAME" | tee -a ${ERRFILE}
    fi
}

# ------------------------------------------------------------------------------
# MAIN Program -----------------------------------------------------------------
# ------------------------------------------------------------------------------
typeset    INST
typeset    INSTNR   # INST in text format
typeset -i INSTINT  # INST in integer format
typeset    INSTTYPE
typeset    DEVGRP
typeset    HORCMFILE
typeset    CONSISTENCY_CHECK=n


# set PATH
export PATH=/bin:/usr/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/contrib/bin:/HORCM

# Argument Handling ------------------------------------------------------------

WhoAmI        # must be root to continue

while getopts ":g:c" opt; do
  case $opt in
    g) DEVGRP="$OPTARG" ;;
    c) CONSISTENCY_CHECK=y ;;
    *) echo "Invalid argument: ${OPTARG}.\n"
       Usage ;;
  esac
done

shift $(( OPTIND - 1 ))

INST=$1

if [ "$#" = "0" ]; then
    Usage
    exit 1
fi

# check INST format and existance of horcm file

case $INST in
   BC[0-9]*) INSTTYPE=BC ;;
   CA[0-9]*) INSTTYPE=CA ;;
   *) echo "bad format for INST: $INST"
      Usage
      ;;
esac
INSTNR=${INST##BC}   # remove BC prefix from $INST
INSTNR=${INSTNR##CA} # remove CA prefix from $INSTNR so only the number remains
INSTINT=${INSTNR}    # move INSTNR to INSTINT so that any leading 0 get removed
HORCMFILE=/etc/horcm${INSTINT}.conf

[ -f ${HORCMFILE} ] || { echo "${HORCMFILE} doesn't exist."; exit 1
                       }

# do the work ------------------------------------------------------------------
# extract the device group names from the HORCMFILE and run for loop on it

for DevGrp in $(raidqry -g -I${INST} | tail +2 | awk '{print $2}' | sort)
     do
         if [[ -z "${DEVGRP}" || "${DEVGRP}" = "${DevGrp}" ]] # if DEVGRP is defined then only execute this for the select DEVGRP
         then printf "%-80.80s\n" "$DevGrp --------------------------------------------------------------"
              if [[ "${CONSISTENCY_CHECK}" = "y" ]]
              then 
                   {
                   if [[ "${INSTTYPE}" = CA ]]
                   then pairdisplay -I${INST} -g ${DevGrp} -CLI -fcxd |
                        #ls /dev/r*disk/* | raidscan -ICA0 -find verify -fd | awk '$2 != "-" {print $2, $1}'| grep gtslora1|sort

                               grep -v '^Group' | awk '{print $7, $8, $9, $10}' | sort | uniq -c 
                   else pairdisplay -I${INST} -g ${DevGrp} -CLI -fcxd |
                               grep -v '^Group' | awk '{print $8, $9}'          | sort | uniq -c
                   fi
                   } | while read nr rest
                       do printf "%3d devices are %s.\n" $nr "$rest"
                       done
              else 
                   pairdisplay -I${INST} -g ${DevGrp} -CLI -fcxde
              fi
         fi
     done

# End processing ---------------------------------------------------------------

exit 0

# ----------------------------------------------------------------------------
