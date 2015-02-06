#!/bin/bash
source "$(find / -name ".CPprofile.sh" | grep -Em1 "^")" # Grep to limit matches to one since IPSO 'find' doesn't support -quit.

if [[ "$(uname -s)" == "IPSO" ]]; then # IPSO compatibility - stat output needs '-x' for parsing.
	compatible_stat() {
		\stat -x $*
	}
else
	compatible_stat() {
		\stat $*
	}
fi

# Variables
dependencies=("find" "cat" "kill" "echo" "bash" "printf" "stat" "grep" "sleep" "logger" "cpwd_admin")
do_action_syslog=1
do_action_restartdaemon=1
verbose=0
MESSAGE_SYSLOG='Firewall is logging locally.'
MESSAGE_DEPENDENCYFAIL='ERROR: Required dependency is missing:'
SECONDS_BETWEEN_MEASUREMENT=15

# Dependency check
for dependency in "${dependencies[@]}"; do
	which $dependency &> /dev/null || { printf "%s %s\n" "$MESSAGE_DEPENDENCYFAIL" "$dependency" >&2; exit 1; }
done

exec 3>/dev/null
[[ "$verbose" == "1" ]] && exec 3>&2

# Actions
action_syslog() {
	vs="$1"
	printf "%s\n" "Performing syslog action" >&3
	logger -t "Log monitor" -p emerg "${vs##*/}: $MESSAGE_SYSLOG"
}

action_restartdaemon() {
	vs="$1"
	printf "%s\n" "Performing restart fwd action" >&3
	if [[ -n "$vs" ]]; then
		# Stopping individual VS daemons w/ cpwd_admin is flaky at best.  We will just kill by pid and let cpwd_admin revive in time.
		kill $(<"${vs}/tmp/fwd.pid") >&3
	else
		# For FW-1 we can revive fwd nearly instantaneously.
		cpwd_admin stop -name FWD -path "$FWDIR/bin/fw" -command "fw kill fwd" >&3
		cpwd_admin start -name FWD -path "$FWDIR/bin/fwd" -command "fwd" >&3
	fi
}

actions() {
	architecture="$1"
	vs="$2"
	printf "%s\n" "Taking actions" >&3
	[[ "$do_action_syslog" == "1" ]] && action_syslog "$vs"
	[[ "$do_action_restartdaemon" == "1" ]] && action_restartdaemon "$vs"
}

# Checks
check_vsx() {
	error_level=0
	for vs in $FWDIR/CTX/*; do
		printf "%s\n" "Checking ${vs##*/}" >&3
		log_location="$vs/log/fw.log"
		printf "%s %s\n" "Log location:" "$log_location" >&3
		first_size=$(stat "$log_location" | grep -oE 'Size:\ [0-9]+' | grep -oE '[0-9]+')
		printf "%s %s\n" "First size of log:" "$first_size" >&3
		printf "%s\n" "Sleeping before second size sampling..." >&3
		sleep ${SECONDS_BETWEEN_MEASUREMENT:-15}
		second_size=$(stat "$log_location" | grep -oE 'Size:\ [0-9]+' | grep -oE '[0-9]+')
		printf "%s %s\n" "Second size of log:" "$second_size" >&3
		if (( "$second_size" > "$first_size" )); then
			actions "vsx" "$vs"
			(( error_level=error_level+1 ))
		fi
	done
	exit "$error_level"
}

check_fw1() {
	error_level=0
	log_location="$FWDIR/log/fw.log"
	printf "%s %s\n" "Log location:" "$log_location" >&3
	first_size=$(compatible_stat "$log_location" | grep -oE 'Size:\ [0-9]+' | grep -oE '[0-9]+')
	printf "%s %s\n" "First size of log:" "$first_size" >&3
	printf "%s\n" "Sleeping before second size sampling..." >&3
	sleep ${SECONDS_BETWEEN_MEASUREMENT:-15}
	second_size=$(compatible_stat "$log_location" | grep -oE 'Size:\ [0-9]+' | grep -oE '[0-9]+')
	printf "%s %s\n" "Second size of log:" "$second_size" >&3
	if (( "$second_size" > "$first_size" )); then
		actions "fw1"
		(( error_level=error_level+1 ))
	fi
	exit "$error_level"
}

if [[ -d "$FWDIR/CTX" ]]; then
	printf "%s\n" "Detected VSX" >&3
	check_vsx
else
	printf "%s\n" "Detected FW-1" >&3
	check_fw1
fi

# Diagnostics???
# Future area to try to determine *why* logs stopped streaming.
