#!/bin/bash
# ups-monitor.sh (c)2026 Colas Nahaboo. MIT license.
# Source: https://github.com/ColasNahaboo/ups-monitor.sh
export VERSION=1.0.0

# Monitor UPS. On a power cut event:
# at 90% battery, shutdown first servers: e.g: store and backup
# at 80% battery, shutdown extra servers: e.g: colas
# at 20% battery, shutdown self, and put UPS in sleep mode
# These settings (and others) can be changed locally in /etc/ups-monitor.conf
# If the file /tmp/NOUPSMON exists just print actions but do not perform them
# logs into /var/log/ups-monitor/
#   - last.status: the last complete status triggering a mail alert
#   - YYYY-MM.log: the log of status changes
# with a "clean" argument performs daily cleanup in the log dir
# Trigger it by a root crontab daily entry:
# 01 00 * * * ups-monitor.sh clean

# started via config in /etc/systemd/system/ups-logic.service and
#   sudo systemctl enable ups-logic.service
# check service is running: sudo journalctl -u ups-logic.service -f
# then (redo after each change in this file)
#   sudo systemctl restart ups-logic.service

#====================== CONFIGURATION ======================
UPS_NAME="eaton5sc@localhost"         # UPS device USB location
UPS_DESC="Eaton 5SC UPS on $HOSTNAME" # Used in the subjects of the email alerts
# thresholds in battery charge in %
LOW_BATT_FIRST=90
LOW_BATT_XTRA=80
LOW_BATT_SELF=20
# servers names to shutdown when thresholds reached. Bash arrays.
# Can be empty (), one server (foo), or many (foo bar gee)
SERVERS_FIRST=(store backup)
SERVERS_XTRA=(colas)

CHECK_DELAY=5                   # 5s is the sweet spot. Do not go higher.
SSH_TIMEOUT=10                  # do no wait forever shutdowning servers
ERROR_DELAY=300                 # wait longer when error detected
UPS_ADMIN_PASS="admin"          # the password on the UPS unit
MAILTO="root"                   # where to mail alerts
LOG="/var/log/ups-monitor"      # where to log
RETRIES=100                     # retries on "Data stale"
KEEP_LOGS=365                   # remove logs older than KEEP_LOGS days

# Utilities
# Note that these too can be redefined in the config file

# once the power is back, reset to a "normal" state of the variables
resetvars(){
    DOIT=                       # can be empty(undefined) / true / false
    POWER_LOST=false            # booleans: true/false
    FIRST_DONE=false
    XTRA_DONE=false
    BATT_DONE=false
    STALE_DONE=false
    PREV_STATUS=                # previous value of STATUS
}

# non-blocking remote shutdown of servers in arguments.
# Must be able to ssh to them as root without a password
remoteshut(){
    $DOIT && for host in "$@"; do
        ssh -t -o "$SSHTO" "$host" "sudo shutdown -h now"&
    done
}

# email message to the admin (stdin as body, args as subject), and log subject
info(){
    local isodate
    mail -s "$UPS_DESC: $*" $MAILTO
    isodate=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$isodate $*" >>"$LOG/$(date +%Y-%m).log"
}

#====================== END OF CONFIGURATION ======================
# local configuration (bash syntax) overriding the above vars or functions
# shellcheck disable=SC1091
[[ -e /etc/ups-monitor.conf ]] && . /etc/ups-monitor.conf

# Internal Vars Inits
SSHTO="ConnectTimeout=$SSH_TIMEOUT"
NODOIT=/tmp/NOUPSMON
[[ -f "$LOG" ]] && rm -f "$LOG"
[[ -d "$LOG" ]] || mkdir -p "$LOG"
resetvars

# Daily cleanup mode: clean and exit
if [[ "$1" == clean ]]; then
    find "$LOG" -type f -mtime +"$KEEP_LOGS" -delete # remove old logs
    upsc "$UPS_NAME" 2>/dev/null >"$LOG"/daily.status
    exit 0
fi

# Main infinite loop
while true; do
    # Get UPS Status and Battery Level
    # We use 'ups.status' and 'battery.charge'
    RAW_STATUS=$(upsc "$UPS_NAME" ups.status 2>/dev/null || echo 'Data stale')
    n=0
    while [[ "$RAW_STATUS" == *"Data stale"* ]]; do
        if ((n++ >= RETRIES)); then
            upsc "$UPS_NAME" 2>/dev/null >$LOG/last.status
            $STALE_DONE || info "Error! Data stale or driver busy." <$LOG/last.status
            STALE_DONE=true
            sleep $ERROR_DELAY
            break
        fi
        sleep 2
    done
    STATUS="$RAW_STATUS"
    # log any status changes, record values of over- and under- voltages 
    if [[ "$STATUS" != "$PREV_RAW_STATUS" ]]; then
        # Trim / boost are no actual problems, but log them just for info
        if [[ "$STATUS" =~ (TRIM|BOOST) ]]; then
            voltage=' input: '$(upsc "$UPS_NAME" input.voltage 2>/dev/null)'V'
        else
            voltage=
        fi
        isodate=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$isodate $STATUS$voltage" >>"$LOG/$(date +%Y-%m).log"
        PREV_RAW_STATUS="$STATUS"
    fi
    # check if battery flagged as "To Replace" internally by the UPS. Just warn
    if [[ "$STATUS" == *' RB'* ]] && ! $BATT_DONE; then
        info "*** REPLACE BATTERY! ***" <$LOG/last.status
        BATT_DONE=true
    fi
    # Check if we are On Battery (OB)
    if [[ "$STATUS" == OB* ]]; then
        BATT=$(upsc "$UPS_NAME" battery.charge 2>/dev/null)
        if [[ -z "$DOIT" ]]; then
            info "Power lost, battery $BATT%" <<<"Power Lost! Status: $STATUS, Battery: $BATT%"
            DOIT=true
            [[ -e "$NODOIT" ]] && DOIT=false
            $DOIT || echo "### Dry run mode, no actions taken"
        fi
        
        # now gradually shutdown servers as the battery declines
        # 1. First shutdown
        if (( BATT < LOW_BATT_FIRST )); then
            if ! $FIRST_DONE; then
                info "Battery $BATT%, shutting down FIRST servers: ${SERVERS_FIRST[*]}" <<<"Battery=$BATT% < ${LOW_BATT_FIRST}%."
                remoteshut "${SERVERS_FIRST[@]}"
                FIRST_DONE=true
            fi
        fi
        # 2. Xtra shutdown
        if (( BATT < LOW_BATT_XTRA )); then
            if ! $XTRA_DONE; then
                info "Battery $BATT%, shutting down XTRA servers: ${SERVERS_XTRA[*]}" <<<"Battery=$BATT% < ${LOW_BATT_XTRA}%."
                remoteshut "${SERVERS_XTRA[@]}"
                XTRA_DONE=true
            fi
        fi
        # 3. ALL shutdown if battery % is low or the LB (Low Battery) status
        if (( BATT < LOW_BATT_SELF ))  || [[ "$STATUS" == *' LB'* ]]; then
            info "Shutting down $HOSTNAME, and putting the UPS in standby" <<<"Battery=$BATT% < ${LOW_BATT_SELF}% ==> Final shutdown sequence..."
            # Kill UPS power and shutdown this local host
            # Note that the UPS will wait 30s before actually shutting down
            $DOIT && upscmd -u admin -p "$UPS_ADMIN_PASS" "$UPS_NAME" shutdown.return
            sync
            $DOIT && shutdown -h now
        fi
    elif [[ "$STATUS" == OL* ]]; then
        # Back on Line Power (OL)
        if $POWER_LOST; then
            BATT=$(upsc "$UPS_NAME" battery.charge 2>/dev/null)
            if $XTRA_DONE; then
                TODO="Please restart ${SERVERS_FIRST[*]} ${SERVERS_XTRA[*]}"
            elif $FIRST_DONE; then
                TODO="Please restart ${SERVERS_FIRST[*]}"
            else
                TODO="No servers to restart"
            fi
            info "Power restored at battery $BATT%" <<<"$TODO"
            upsc "$UPS_NAME" 2>/dev/null >$LOG/last.status
            resetvars
        fi
    elif [[ "$STATUS" == WAIT* ]]; then # busy self-test, ignore
        :
    elif [[ "$STATUS" == OL*OFF* ]]; then # no connect servers, ignore
        :
    else
        if [[ "$STATUS" != "$PREV_STATUS" ]]; then
            upsc "$UPS_NAME" 2>/dev/null >$LOG/last.status
            info "Unknown status: $STATUS" <$LOG/last.status
            PREV_STATUS="$STATUS"   # mail only once
        fi
        sleep $ERROR_DELAY
    fi

    sleep $CHECK_DELAY
done
