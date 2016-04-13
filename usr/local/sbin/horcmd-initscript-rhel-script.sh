#!/bin/bash
if [[ "$(id -u)" != "0" ]]; then
    echo "Must be root - exit"
    exit 1
fi
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "Script $0 is meant for Linux 0nly"
fi
# First check it HORCM is installed, otherwise, it makes no sense to run this script
if [[ ! -d /HORCM/usr/bin ]]; then
    echo "HORCM seems not to be installed as /HORCM/usr/bin was not present?"
    exit 1
fi

echo "Creating init script /etc/init.d/horcmd"
cat > /etc/init.d/horcmd <<EOF
#!/bin/sh
#
# horcmd - To start automatically the HORCM instances
#
# chkconfig:   345 20 80
# description: HORCM daemon(s) required for Business Copy \\
#              with the RAID Manager software of XP Storage Array

### BEGIN INIT INFO
# Provides:
# Required-Start:
# Required-Stop:
# Should-Start:
# Should-Stop:
# Default-Start:
# Default-Stop:
# Short-Description:
# Description:
### END INIT INFO

# Source function library.
. /etc/rc.d/init.d/functions

horcm_dir="/HORCM/usr/bin"
horcmstart="\$horcm_dir/horcmstart.sh"
horcmshutdown="\$horcm_dir/horcmshutdown.sh"
prog="horcmd"
#config="<path to major config file>"

# /etc/sysconfig/\$prog defines the RAID_MANAGER_INSTANCES variable:
#   cat /etc/sysconfig/horcmd
#   RAID_MANAGER_INSTANCES="0"
if [ -e /etc/sysconfig/\$prog ]; then
    . /etc/sysconfig/\$prog
else
    echo "ERROR: File /etc/sysconfig/\$prog not found"
    exit 1
fi

lockfile=/var/lock/subsys/\$prog

start() {
    [ -x \$horcmstart ] || exit 5
    #[ -f \$config ] || exit 6
    echo -n \$"Starting \$prog: "
    # if not running, start it up here, usually something like "daemon \$exec"
    \$horcmstart \$RAID_MANAGER_INSTANCES
    retval=\$?
    echo
    [ \$retval -eq 0 ] && touch \$lockfile
    return \$retval
}

stop() {
    echo -n \$"Stopping \$prog: "
    # stop it here, often "killproc \$prog"
    \$horcmshutdown \$RAID_MANAGER_INSTANCES
    retval=\$?
    echo
    [ \$retval -eq 0 ] && rm -f \$lockfile
    return \$retval
}

restart() {
    stop
    start
}

reload() {
    restart
}

force_reload() {
    restart
}

rh_status() {
    # run checks to determine if the service is running or use generic status
    # cannot use the generic way because horcmd_00 is not the same as horcmd
    #status \$prog
    ps ax | grep \${prog}_ | grep -v grep >/dev/null
    retval=\$?
    if [ \$retval -eq 0 ] ; then
        ps ax | grep \${prog}_ | grep -v grep
    else
        echo "No horcmd daemons running"
    fi
    return \$retval
}

rh_status_q() {
    rh_status >/dev/null 2>&1
}


case "\$1" in
    start)
        rh_status_q && exit 0
        \$1
        ;;
    stop)
        rh_status_q || exit 0
        \$1
        ;;
    restart)
        \$1
        ;;
    reload)
        rh_status_q || exit 7
        \$1
        ;;
    force-reload)
        force_reload
        ;;
    status)
        rh_status
        ;;
    condrestart|try-restart)
        rh_status_q || exit 0
        restart
        ;;
    *)
        echo \$"Usage: \$0 {start|stop|status|restart|condrestart|try-restart|reload|force-reload}"
        exit 2
esac
exit \$?

EOF

chmod +x /etc/init.d/horcmd
echo "Checking /etc/init.d/horcmd script on syntax errors"
bash -n /etc/init.d/horcmd

echo "This is what is currently running (horcmd daemons; could be nothing):"
ps ax|grep horcmd_ | grep -v grep

RAID_MANAGER_INSTANCES="$(echo $(ps ax|grep horcmd_ | grep -v grep | awk '{print $5}' | cut -d_ -f2 | sed -e 's/^0//'))"
echo "Creating /etc/sysconfig/horcmd file to define RAID_MANAGER_INSTANCES variable"
cat > /etc/sysconfig/horcmd <<EOF
RAID_MANAGER_INSTANCES="$RAID_MANAGER_INSTANCES"
EOF

echo "Configured horcmd to start RAID HORCM Instance(s) $RAID_MANAGER_INSTANCES"
cat /etc/sysconfig/horcmd
echo
echo "If there are other RAID HORCM instances running then edit file"
echo "/etc/sysconfig/horcmd and modify variable RAID_MANAGER_INSTANCES"
echo "E.g. RAID_MANAGER_INSTANCES=\"0 1\""
echo
echo

echo "Configure the run-levels to start horcmd:"
chkconfig --add horcmd
chkconfig --list horcmd

echo
echo "To view the status of the daemons, use command:"
echo "/etc/init.d/horcmd status"
echo
echo "To stop horcmd daemons use:"
echo "/etc/init.d/horcmd stop"
echo
echo "To start horcmd daemons use:"
echo "/etc/init.d/horcmd start"
echo
echo "Done."
