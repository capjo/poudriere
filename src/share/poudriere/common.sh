#!/bin/sh
# 
# Copyright (c) 2010-2013 Baptiste Daroussin <bapt@FreeBSD.org>
# Copyright (c) 2010-2011 Julien Laffaye <jlaffaye@FreeBSD.org>
# Copyright (c) 2012-2014 Bryan Drewery <bdrewery@FreeBSD.org>
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

BSDPLATFORM=`uname -s | tr '[:upper:]' '[:lower:]'`
. ${SCRIPTPREFIX}/include/common.sh.${BSDPLATFORM}
BLACKLIST=""
EX_SOFTWARE=70

# Return true if ran from bulk/testport, ie not daemon/status/jail
was_a_bulk_run() {
	[ "${SCRIPTPATH##*/}" = "bulk.sh" -o "${SCRIPTPATH##*/}" \
	    = "testport.sh" ]
}
# Return true if in a bulk or other jail run that needs to shutdown the jail
was_a_jail_run() {
	was_a_bulk_run ||  [ "${SCRIPTPATH##*/}" = "pkgclean.sh" ]
}
# Return true if output via msg() should show elapsed time
should_show_elapsed() {
	[ -z "${TIME_START}" ] && return 1
	[ "${NO_ELAPSED_IN_MSG:-0}" -eq 1 ] && return 1
	case "${SCRIPTPATH##*/}" in
		daemon.sh) ;;
		help.sh) ;;
		queue.sh) ;;
		status.sh) ;;
		version.sh) ;;
		*) return 0 ;;
	esac
	return 1
}

not_for_os() {
	local os=$1
	shift
	[ "${os}" = "${BSDPLATFORM}" ] && err 1 "This is not supported on ${BSDPLATFORM}: $@"
}

err() {
	trap '' SIGINFO
	export CRASHED=1
	if [ $# -ne 2 ]; then
		err 1 "err expects 2 arguments: exit_number \"message\""
	fi
	# Try to set status so other processes know this crashed
	# Don't set it from children failures though, only master
	if [ -z "${PARALLEL_CHILD}" ] && was_a_bulk_run; then
		if [ -n "${MY_JOBID}" ]; then
			bset ${MY_JOBID} status "${EXIT_STATUS:-crashed:}" \
			    2>/dev/null || :
		else
			bset status "${EXIT_STATUS:-crashed:}" 2>/dev/null || :
		fi
	fi
	msg_error "$2" || :
	# Avoid recursive err()->exit_handler()->err()... Just let
	# exit_handler() cleanup.
	if [ ${ERRORS_ARE_FATAL:-1} -eq 1 ]; then
		exit $1
	else
		return 0
	fi
}

# Message functions that depend on VERBOSE are stubbed out in post_getopts.

msg_n() {
	local -; set +x
	local now elapsed

	elapsed=
	if should_show_elapsed; then
		now=$(clock -monotonic)
		calculate_duration elapsed "$((${now} - ${TIME_START:-0}))"
		elapsed="[${elapsed}] "
	fi
	if [ -n "${COLOR_ARROW}" ] || [ -z "${1##*\033[*}" ]; then
		printf "${elapsed}${DRY_MODE}${COLOR_ARROW}====>>${COLOR_RESET} ${1}${COLOR_RESET_REAL}"
	else
		printf "${elapsed}${DRY_MODE}====>> ${1}"
	fi
}

msg() {
	msg_n "$@""\n"
}

msg_verbose() {
	msg_n "$@""\n"
}

msg_error() {
	local -; set +x
	if [ -n "${MY_JOBID}" ]; then
		# Send colored msg to bulk log...
		COLOR_ARROW="${COLOR_ERROR}" job_msg "${COLOR_ERROR}Error: $1"
		# And non-colored to buld log
		msg "Error: $1" >&2
	elif [ ${OUTPUT_REDIRECTED:-0} -eq 1 ]; then
		# Send to true stderr
		COLOR_ARROW="${COLOR_ERROR}" msg "${COLOR_ERROR}Error: $1" >&4
	else
		COLOR_ARROW="${COLOR_ERROR}" msg "${COLOR_ERROR}Error: $1" >&2
	fi
	return 0
}

msg_dev() {
	COLOR_ARROW="${COLOR_DEV}" \
	    msg_n "${COLOR_DEV}Dev: $@""\n" >&2
}

msg_debug() {
	COLOR_ARROW="${COLOR_DEBUG}" \
	    msg_n "${COLOR_DEBUG}Debug: $@""\n" >&2
}

msg_warn() {
	COLOR_ARROW="${COLOR_WARN}" \
	    msg_n "${COLOR_WARN}Warning: $@""\n" >&2
}

job_msg() {
	local -; set +x
	local now elapsed NO_ELAPSED_IN_MSG output

	if [ -n "${MY_JOBID}" ]; then
		NO_ELAPSED_IN_MSG=0
		now=$(clock -monotonic)
		calculate_duration elapsed "$((${now} - ${TIME_START_JOB:-${TIME_START:-0}}))"
		output="[${COLOR_JOBID}${MY_JOBID}${COLOR_RESET}][${elapsed}] $1"
	else
		output="$@"
	fi
	if [ ${OUTPUT_REDIRECTED:-0} -eq 1 ]; then
		# Send to true stdout (not any build log)
		msg_n "${output}\n" >&3
	else
		msg_n "${output}\n"
	fi
}

# Stubbed until post_getopts
job_msg_verbose() {
	local -; set +x
	job_msg "$@"
}

job_msg_warn() {
	COLOR_ARROW="${COLOR_WARN}" \
	    job_msg "${COLOR_WARN}Warning: $@"
}

prompt() {
	[ $# -eq 1 ] || eargs prompt message
	local message="$1"
	local answer

	msg_n "${message} [y/N] "
	read answer
	case "${answer}" in
		[Yy][Ee][Ss]|[Yy][Ee]|[Yy])
			return 0
			;;
	esac

	return 1
}

confirm_if_tty() {
	[ $# -eq 1 ] || eargs confirm_if_tty message
	local message="${1}"

	[ -t 0 ] || return 0
	prompt "${message}"
}

# Handle needs after processing arguments.
post_getopts() {
	# Short-circuit verbose functions to save CPU
	if ! [ ${VERBOSE} -gt 2 ]; then
		msg_dev() { }
	fi
	if ! [ ${VERBOSE} -gt 1 ]; then
		msg_debug() { }
	fi
	if ! [ ${VERBOSE} -gt 0 ]; then
		msg_verbose() { }
		job_msg_verbose() { }
	fi
}

_mastermnt() {
	local hashed_name mnt mnttest mnamelen

	mnamelen=$(grep "#define[[:space:]]MNAMELEN" \
	    /usr/include/sys/mount.h 2>/dev/null | awk '{print $3}')

	mnt="${POUDRIERE_DATA}/.m/${MASTERNAME}/ref"
	mnttest="${mnt}/compat/linux/proc"

	if [ -n "${mnamelen}" ] && \
	    [ ${#mnttest} -ge $((${mnamelen} - 1)) ]; then
		hashed_name=$(sha256 -qs "${MASTERNAME}" | \
		    awk '{print substr($0, 0, 6)}')
		mnt="${POUDRIERE_DATA}/.m/${hashed_name}/ref"
		mnttest="${mnt}/var/db/ports"
		[ ${#mnttest} -ge $((${mnamelen} - 1)) ] && \
		    err 1 "Mountpath '${mnt}' exceeds system MNAMELEN limit of ${mnamelen}. Unable to mount. Try shortening BASEFS."
		msg_warn "MASTERNAME '${MASTERNAME}' too long for mounting, using hashed version of '${hashed_name}'"
	fi

	setvar "$1" "${mnt}"
	# MASTERMNTROOT
	setvar "${1}ROOT" "${mnt%/ref}"
}

_my_path() {
	if [ -z "${MY_JOBID}" ]; then
		setvar "$1" "${MASTERMNT}"
	elif [ -n "${MASTERMNTROOT}" ]; then
		setvar "$1" "${MASTERMNTROOT}/${MY_JOBID}"
	else
		setvar "$1" "${MASTERMNT}/../${MY_JOBID}"

	fi
}

_my_name() {
	setvar "$1" "${MASTERNAME}${MY_JOBID+-job-${MY_JOBID}}"
}
 
_log_path_top() {
	setvar "$1" "${POUDRIERE_DATA}/logs/${POUDRIERE_BUILD_TYPE}"
}

_log_path_jail() {
	local log_path_top

	_log_path_top log_path_top
	setvar "$1" "${log_path_top}/${MASTERNAME}"
}

_log_path() {
	local log_path_jail

	_log_path_jail log_path_jail
	setvar "$1" "${log_path_jail}/${BUILDNAME}"
}

# Call function with vars set:
# log MASTERNAME BUILDNAME jailname ptname setname
for_each_build() {
	[ -n "${BUILDNAME_GLOB}" ] || \
	    err 1 "for_each_build requires BUILDNAME_GLOB"
	[ -n "${SHOW_FINISHED}" ] || \
	    err 1 "for_each_build requires SHOW_FINISHED"
	[ $# -eq 1 ] || eargs for_each_build action
	local action="$1"
	local MASTERNAME BUILDNAME buildname jailname ptname setname
	local log_top

	POUDRIERE_BUILD_TYPE="bulk" _log_path_top log_top
	[ -d "${log_top}" ] || err 1 "Log path ${log_top} does not exist."
	cd ${log_top}

	found_jobs=0
	for mastername in *; do
		# Check empty dir
		case "${mastername}" in
			"*") break ;;
		esac
		[ -L "${mastername}/latest" ] || continue
		MASTERNAME=${mastername}
		[ "${MASTERNAME}" = "latest-per-pkg" ] && continue
		[ ${SHOW_FINISHED} -eq 0 ] && ! jail_runs ${MASTERNAME} && \
		    continue

		# Look for all wanted buildnames (will be 1 or Many(-a)))
		for buildname in ${mastername}/${BUILDNAME_GLOB}; do
			# Check for no match. If not using a glob ensure the
			# file exists otherwise check for the glob coming back
			if [ "${BUILDNAME_GLOB%\**}" != \
			    "${BUILDNAME_GLOB}" ]; then
				case "${buildname}" in
					# Check no results
					"${mastername}/${BUILDNAME_GLOB}")
						break
						;;
					# Skip latest if from a glob, let it be
					# found normally.
					"${mastername}/latest")
						continue
						;;
					# Don't want latest-per-pkg
					"${mastername}/latest-per-pkg")
						continue
						;;
				esac
			else
				# No match
				[ -e "${buildname}" ] || break
			fi
			buildname="${buildname#${mastername}/}"
			BUILDNAME="${buildname}"
			# Unset so later they can be checked for NULL (don't
			# want to lookup again if value looked up is empty
			unset jailname ptname setname
			# Try matching on any given JAILNAME/PTNAME/SETNAME,
			# and if any don't match skip this MASTERNAME entirely.
			# If the file is missing it's a legacy build, skip it
			# but not the entire mastername if it has a match.
			if [ -n "${JAILNAME}" ]; then
				if _bget jailname jailname 2>/dev/null; then
					[ "${jailname}" = "${JAILNAME}" ] || \
					    continue 2
				else
					case "${MASTERNAME}" in
						${JAILNAME}-*) ;;
						*) continue 2 ;;
					esac
					continue
				fi
			fi
			if [ -n "${PTNAME}" ]; then
				if _bget ptname ptname 2>/dev/null; then
					[ "${ptname}" = "${PTNAME}" ] || \
					    continue 2
				else
					case "${MASTERNAME}" in
						*-${PTNAME}) ;;
						*) continue 2 ;;
					esac
					continue
				fi
			fi
			if [ -n "${SETNAME}" ]; then
				if _bget setname setname 2>/dev/null; then
					[ "${setname}" = "${SETNAME%0}" ] || \
					    continue 2
				else
					case "${MASTERNAME}" in
						*-${SETNAME%0}) ;;
						*) continue 2 ;;
					esac
					continue
				fi
			fi
			# Dereference latest into actual buildname
			[ "${buildname}" = "latest" ] && \
			    _bget BUILDNAME buildname 2>/dev/null
			# May be blank if build is still starting up
			[ -z "${BUILDNAME}" ] && continue 2

			found_jobs=$((${found_jobs} + 1))

			# Lookup jailname/setname/ptname if needed. Delayed
			# from earlier for performance for -a
			[ -z "${jailname+null}" ] && \
			    _bget jailname jailname 2>/dev/null || :
			[ -z "${setname+null}" ] && \
			    _bget setname setname 2>/dev/null || :
			[ -z "${ptname+null}" ] && \
			    _bget ptname ptname 2>/dev/null || :
			log=${mastername}/${BUILDNAME}

			${action}
		done

	done
	cd ${OLDPWD}
}

stat_humanize() {
	xargs -0 stat -f '%i %z' | \
	    sort -u | \
	    awk '{total += $2} END {print total}' | \
	    awk -f ${AWKPREFIX}/humanize.awk
}

do_confirm_delete() {
	[ $# -eq 4 ] || eargs do_confirm_delete badfiles_list \
	    reason_plural_object answer DRY_RUN
	local filelist="$1"
	local reason="$2"
	local answer="$3"
	local DRY_RUN="$4"
	local file_cnt hsize ret

	file_cnt=$(wc -l ${filelist} | awk '{print $1}')
	if [ ${file_cnt} -eq 0 ]; then
		msg "No ${reason} to cleanup"
		return 2
	fi

	msg_n "Calculating size for found files..."
	hsize=$(cat ${filelist} | \
	    tr '\n' '\000' | \
	    xargs -0 -J % find % -print0 | \
	    stat_humanize)
	echo " done"

	msg "These ${reason} will be deleted:"
	cat ${filelist}
	msg "Removing these ${reason} will free: ${hsize}"

	if [ ${DRY_RUN} -eq 1 ];  then
		msg "Dry run: not cleaning anything."
		return 2
	fi

	if [ -z "${answer}" ]; then
		prompt "Proceed?" && answer="yes"
	fi

	ret=0
	if [ "${answer}" = "yes" ]; then
		msg_n "Removing files..."
		cat ${filelist} | tr '\n' '\000' | \
		    xargs -0 -J % \
		    find % -mindepth 0 -maxdepth 0 -exec rm -rf {} +
		echo " done"
		ret=1
	fi
	return ${ret}
}

# It may be defined as a NOP for tests
if ! type injail >/dev/null 2>&1; then
injail() {
	if [ "${USE_JEXECD}" = "no" ]; then
		injail_tty "$@"
	else
		local name

		_my_name name
		[ -n "${name}" ] || err 1 "No jail setup"
		rexec -s ${MASTERMNT}/../${name}${JNETNAME:+-${JNETNAME}}.sock \
			-u ${JUSER:-root} "$@"
	fi
}
fi

injail_tty() {
	local name

	_my_name name
	[ -n "${name}" ] || err 1 "No jail setup"
	if [ ${JEXEC_LIMITS:-0} -eq 1 ]; then
		jexec -U ${JUSER:-root} ${name}${JNETNAME:+-${JNETNAME}} \
			${JEXEC_LIMITS+/usr/bin/limits} \
			${MAX_MEMORY_BYTES:+-v ${MAX_MEMORY_BYTES}} \
			${MAX_FILES:+-n ${MAX_FILES}} \
			"$@"
	else
		jexec -U ${JUSER:-root} ${name}${JNETNAME:+-${JNETNAME}} \
			"$@"
	fi
}

jstart() {
	local name network

	network="${localipargs}"

	[ "${RESTRICT_NETWORKING}" = "yes" ] || network="${ipargs}"

	_my_name name
	jail -c persist name=${name} \
		path=${MASTERMNT}${MY_JOBID+/../${MY_JOBID}} \
		host.hostname=${BUILDER_HOSTNAME-${name}} \
		${network} ${JAIL_PARAMS} \
		allow.socket_af allow.raw_sockets allow.chflags allow.sysvipc
	[ "${USE_JEXECD}" = "yes" ] && \
	    jexecd -j ${name} -d ${MASTERMNT}/../ \
	    ${MAX_MEMORY_BYTES+-m ${MAX_MEMORY_BYTES}} \
	    ${MAX_FILES+-n ${MAX_FILES}}
	jail -c persist name=${name}-n \
		path=${MASTERMNT}${MY_JOBID+/../${MY_JOBID}} \
		host.hostname=${BUILDER_HOSTNAME-${name}} \
		${ipargs} ${JAIL_PARAMS} \
		allow.socket_af allow.raw_sockets allow.chflags allow.sysvipc
	[ "${USE_JEXECD}" = "yes" ] && \
	    jexecd -j ${name}-n -d ${MASTERMNT}/../ \
	    ${MAX_MEMORY_BYTES+-m ${MAX_MEMORY_BYTES}} \
	    ${MAX_FILES+-n ${MAX_FILES}}
	return 0
}

jail_has_processes() {
	local pscnt

	# 2 = HEADER+ps itself
	pscnt=2
	[ "${USE_JEXECD}" = "yes" ] && pscnt=4
	# Cannot use ps -J here as not all versions support it.
	if [ $(injail ps aux | wc -l) -ne ${pscnt} ]; then
		return 0
	fi
	return 1
}

jkill_wait() {
	injail kill -9 -1 2>/dev/null || :
	while jail_has_processes; do
		sleep 1
		injail kill -9 -1 2>/dev/null || :
	done
}

# Kill everything in the jail and ensure it is free of any processes
# before returning.
jkill() {
	jkill_wait
	JNETNAME="n" jkill_wait
}

jstop() {
	local name

	_my_name name
	jail -r ${name} 2>/dev/null || :
	jail -r ${name}-n 2>/dev/null || :
}

eargs() {
	local fname="$1"
	shift
	case $# in
	0) err ${EX_SOFTWARE} "${fname}: No arguments expected" ;;
	1) err ${EX_SOFTWARE} "${fname}: 1 argument expected: $1" ;;
	*) err ${EX_SOFTWARE} "${fname}: $# arguments expected: $*" ;;
	esac
}

run_hook() {
	local hookfile="${HOOKDIR}/${1}.sh"
	local build_url log_url
	shift

	build_url build_url || :
	log_url log_url || :
	if [ -f "${hookfile}" ]; then
		(
			cd /

			BUILD_URL="${build_url}" \
			LOG_URL="${log_url}" \
			POUDRIERE_BUILD_TYPE=${POUDRIERE_BUILD_TYPE} \
			POUDRIERED="${POUDRIERED}" \
			POUDRIERE_DATA="${POUDRIERE_DATA}" \
			MASTERNAME="${MASTERNAME}" \
			MASTERMNT="${MASTERMNT}" \
			MY_JOBID="${MY_JOBID}" \
			BUILDNAME="${BUILDNAME}" \
			JAILNAME="${JAILNAME}" \
			PTNAME="${PTNAME}" \
			SETNAME="${SETNAME}" \
			PACKAGES="${PACKAGES}" \
			PACKAGES_ROOT="${PACKAGES_ROOT}" \
			/bin/sh "${hookfile}" "$@"
		)
	fi
	return 0
}

log_start() {
	[ $# -eq 1 ] || eargs log_start need_tee
	local need_tee="$1"
	local log log_top
	local latest_log

	_log_path log
	_log_path_top log_top

	logfile="${log}/logs/${PKGNAME}.log"
	latest_log=${log_top}/latest-per-pkg/${PKGNAME%-*}/${PKGNAME##*-}

	# Make sure directory exists
	mkdir -p ${log}/logs ${latest_log}

	:> ${logfile}

	# Link to BUILD_TYPE/latest-per-pkg/PORTNAME/PKGVERSION/MASTERNAME.log
	ln -f ${logfile} ${latest_log}/${MASTERNAME}.log

	# Link to JAIL/latest-per-pkg/PKGNAME.log
	ln -f ${logfile} ${log}/../latest-per-pkg/${PKGNAME}.log

	# Save stdout/stderr for restoration later for bulk/testport -i
	exec 3>&1 4>&2
	OUTPUT_REDIRECTED=1
	# Pipe output to tee(1) or timestamp if needed.
	if [ ${need_tee} -eq 1 ] || [ "${TIMESTAMP_LOGS}" = "yes" ]; then
		[ ! -e ${logfile}.pipe ] && mkfifo ${logfile}.pipe
		if [ ${need_tee} -eq 1 ]; then
			if [ "${TIMESTAMP_LOGS}" = "yes" ]; then
				timestamp < ${logfile}.pipe | tee ${logfile} &
			else
				tee ${logfile} < ${logfile}.pipe &
			fi
		elif [ "${TIMESTAMP_LOGS}" = "yes" ]; then
			timestamp > ${logfile} < ${logfile}.pipe &
		fi
		tpid=$!
		exec > ${logfile}.pipe 2>&1

		# Remove fifo pipe file right away to avoid orphaning it.
		# The pipe will continue to work as long as we keep
		# the FD open to it.
		rm -f ${logfile}.pipe
	else
		# Send output directly to file.
		tpid=
		exec > ${logfile} 2>&1
	fi
}

buildlog_start() {
	local portdir=$1
	local mnt
	local var

	_my_path mnt

	echo "build started at $(date)"
	echo "port directory: ${portdir}"
	echo "building for: $(injail uname -a)"
	echo "maintained by: $(injail /usr/bin/make -C ${portdir} maintainer)"
	echo "Makefile ident: $(ident -q ${mnt}/${portdir}/Makefile|sed -n '2,2p')"
	echo "Poudriere version: ${POUDRIERE_VERSION}"
	echo "Host OSVERSION: ${HOST_OSVERSION}"
	echo "Jail OSVERSION: ${JAIL_OSVERSION}"
	echo "Job Id: ${MY_JOBID}"
	echo
	if [ ${JAIL_OSVERSION} -gt ${HOST_OSVERSION} ]; then
		echo
		echo
		echo
		echo "!!! Jail is newer than host. (Jail: ${JAIL_OSVERSION}, Host: ${HOST_OSVERSION}) !!!"
		echo "!!! This is not supported. !!!"
		echo "!!! Host kernel must be same or newer than jail. !!!"
		echo "!!! Expect build failures. !!!"
		echo
		echo
		echo
	fi
	echo "---Begin Environment---"
	injail /usr/bin/env ${PKGENV} ${PORT_FLAGS}
	echo "---End Environment---"
	echo ""
	echo "---Begin OPTIONS List---"
	injail /usr/bin/make -C ${portdir} showconfig || :
	echo "---End OPTIONS List---"
	echo ""
	for var in CONFIGURE_ARGS CONFIGURE_ENV MAKE_ENV; do
		echo "--${var}--"
		echo "$(injail /usr/bin/env ${PORT_FLAGS} /usr/bin/make -C ${portdir} -V ${var})"
		echo "--End ${var}--"
		echo ""
	done
	echo "--PLIST_SUB--"
	echo "$(injail /usr/bin/env ${PORT_FLAGS} /usr/bin/make -C ${portdir} -V PLIST_SUB | tr ' ' '\n' | grep -v '^$')"
	echo "--End PLIST_SUB--"
	echo ""
	echo "--SUB_LIST--"
	echo "$(injail /usr/bin/env ${PORT_FLAGS} /usr/bin/make -C ${portdir} -V SUB_LIST | tr ' ' '\n' | grep -v '^$')"
	echo "--End SUB_LIST--"
	echo ""
	echo "---Begin make.conf---"
	cat ${mnt}/etc/make.conf
	echo "---End make.conf---"
	if [ -f "${mnt}/etc/make.nxb.conf" ]; then
		echo "---Begin make.nxb.conf---"
		cat ${mnt}/etc/make.nxb.conf
		echo "---End make.nxb.conf---"
	fi

	echo "--Resource limits--"
	injail /bin/sh -c "ulimit -a"
	echo "--End resource limits--"
}

buildlog_stop() {
	[ $# -eq 3 ] || eargs buildlog_stop pkgname origin build_failed
	local pkgname="$1"
	local origin=$2
	local build_failed="$3"
	local log
	local buildtime

	_log_path log
	buildtime=$( \
		stat -f '%N %B' ${log}/logs/${pkgname}.log  | awk -v now=$(clock -epoch) \
		-f ${AWKPREFIX}/siginfo_buildtime.awk |
		awk -F'!' '{print $2}' \
	)

	echo "build of ${origin} ended at $(date)"
	echo "build time: ${buildtime}"
	[ ${build_failed} -gt 0 ] && echo "!!! build failure encountered !!!"

	return 0
}

log_stop() {
	if [ ${OUTPUT_REDIRECTED:-0} -eq 1 ]; then
		exec 1>&3 3>&- 2>&4 4>&-
		OUTPUT_REDIRECTED=0
	fi
	if [ -n "${tpid}" ]; then
		# Give tee a moment to flush buffers
		timed_wait_and_kill 5 $tpid
		unset tpid
	fi
}

read_file() {
	[ $# -eq 2 ] || eargs read_file var_return file
	local var_return="$1"
	local file="$2"
	local _data line
	local ret -

	# var_return may be empty if only $_read_file_lines_read is being
	# used.

	set +e
	_data=
	_read_file_lines_read=0

	if [ ${READ_FILE_USE_CAT:-0} -eq 1 ]; then
		if [ -f "${file}" ]; then
			if [ -n "${var_return}" ]; then
				_data="$(cat "${file}")"
			fi
			_read_file_lines_read=$(wc -l < "${file}")
			_read_file_lines_read=${_read_file_lines_read##* }
			ret=0
		else
			ret=1
		fi
	else
		while :; do
			read -r line
			ret=$?
			case ${ret} in
				# Success, process data and keep reading.
				0) ;;
				# EOF
				1)
					ret=0
					break
					;;
				# Some error or interruption/signal. Reread.
				*) continue ;;
			esac
			if [ -n "${var_return}" ]; then
				# Add extra newline
				[ ${_read_file_lines_read} -gt 0 ] && \
				    _data="${_data}
"
				_data="${_data}${line}"
			fi
			_read_file_lines_read=$((${_read_file_lines_read} + 1))
		done < "${file}" || ret=$?
	fi

	if [ -n "${var_return}" ]; then
		setvar "${var_return}" "${_data}"
	fi

	return ${ret}
}

attr_set() {
	local type=$1
	local name=$2
	local property=$3
	shift 3
	mkdir -p ${POUDRIERED}/${type}/${name}
	echo "$@" > ${POUDRIERED}/${type}/${name}/${property} || :
}

jset() { attr_set jails "$@" ; }
pset() { attr_set ports "$@" ; }

_attr_get() {
	[ $# -eq 4 ] || eargs _attr_get var_return type name property
	local var_return="$1"
	local type="$2"
	local name="$3"
	local property="$4"

	read_file "${var_return}" \
	    "${POUDRIERED}/${type}/${name}/${property}" && return 0
	setvar "${var_return}" ""
	return 1
}

attr_get() {
	local attr_get_data

	if _attr_get attr_get_data "$@"; then
		[ -n "${attr_get_data}" ] && echo "${attr_get_data}"
		return 0
	fi
	return 1
}

jget() { attr_get jails "$@" ; }
_jget() {
	[ $# -eq 3 ] || eargs _jget var_return ptname property
	local var_return="$1"

	shift
	_attr_get "${var_return}" jails "$@"
}
pget() { attr_get ports "$@" ; }
_pget() {
	[ $# -eq 3 ] || eargs _pget var_return ptname property
	local var_return="$1"

	shift
	_attr_get "${var_return}" ports "$@"
}

#build getter/setter
_bget() {
	local var_return id property mnt log file READ_FILE_USE_CAT

	var_return="$1"
	_log_path log
	shift
	if [ $# -eq 2 ]; then
		id="$1"
		shift
	fi
	file=".poudriere.${1}${id:+.${id}}"

	# Use cat(1) to read long list files.
	[ -z "${1##ports.*}" ] && READ_FILE_USE_CAT=1

	read_file "${var_return}" "${log}/${file}" && return 0
	# It may be empty if only a count was being looked up
	# via $_read_file_lines_read hack.
	if [ -n "${var_return}" ]; then
		setvar "${var_return}" ""
	fi
	return 1
}

bget() {
	local bget_data

	if _bget bget_data "$@"; then
		[ -n "${bget_data}" ] && echo "${bget_data}"
		return 0
	fi
	return 1
}

bset() {
	was_a_bulk_run || return 0
	local id property mnt log
	_log_path log
	if [ $# -eq 3 ]; then
		id=$1
		shift
	fi
	property="$1"
	file=.poudriere.${property}${id:+.${id}}
	shift
	[ "${property}" = "status" ] && \
	    echo "$@" >> ${log}/${file}.journal% || :
	echo "$@" > "${log}/${file}"
}

bset_job_status() {
	[ $# -eq 2 ] || eargs bset_job_status status origin
	local status="$1"
	local origin="$2"

	bset ${MY_JOBID} status "${status}:${origin}:${PKGNAME}:${TIME_START_JOB:-${TIME_START}}:$(clock -monotonic)"
}

badd() {
	local id property mnt log
	_log_path log
	if [ $# -eq 3 ]; then
		id=$1
		shift
	fi
	file=.poudriere.${1}${id:+.${id}}
	shift
	echo "$@" >> ${log}/${file} || :
}

update_stats() {
	local type unused
	local -

	if [ -n "${update_stats_done}" ]; then
		return 0
	fi

	set +e

	lock_acquire update_stats || return 1

	for type in built failed ignored; do
		_bget '' "ports.${type}"
		bset "stats_${type}" ${_read_file_lines_read}
	done

	# Skipped may have duplicates in it
	bset stats_skipped $(bget ports.skipped | awk '{print $1}' | \
		sort -u | wc -l)

	lock_release update_stats
}

sigpipe_handler() {
	EXIT_STATUS="sigpipe:"
	SIGNAL="SIGPIPE"
	sig_handler
}

sigint_handler() {
	EXIT_STATUS="sigint:"
	SIGNAL="SIGINT"
	sig_handler
}

sigterm_handler() {
	EXIT_STATUS="sigterm:"
	SIGNAL="SIGTERM"
	sig_handler
}


sig_handler() {
	# Reset SIGTERM handler, just exit if another is received.
	trap - SIGTERM
	# Ignore SIGPIPE for messages
	trap '' SIGPIPE
	# Ignore SIGINT while cleaning up
	trap '' SIGINT
	trap '' SIGINFO
	err 1 "Signal ${SIGNAL} caught, cleaning up and exiting"
}

exit_handler() {
	# Ignore errors while cleaning up
	set +e
	ERRORS_ARE_FATAL=0
	trap '' SIGINFO
	# Avoid recursively cleaning up here
	trap - EXIT SIGTERM
	# Ignore SIGPIPE for messages
	trap '' SIGPIPE
	# Ignore SIGINT while cleaning up
	trap '' SIGINT

	if was_a_bulk_run; then
		log_stop
		# build_queue may have done cd MASTERMNT/.p/pool,
		# but some of the cleanup here assumes we are
		# PWD=MASTERMNT/.p.  Switch back if possible.
		# It will be changed to / in jail_cleanup
		if [ -d "${MASTERMNT}/.p" ]; then
			cd "${MASTERMNT}/.p"
		fi
		# Don't use jail for any caching in cleanup
		SHASH_VAR_PATH="${SHASH_VAR_PATH_DEFAULT}"
	fi

	parallel_shutdown

	if was_a_bulk_run; then
		# build_queue socket
		exec 6<&- 6>&- || :
		coprocess_stop pkg_cacher
	fi

	[ ${STATUS} -eq 1 ] && jail_cleanup

	if was_a_bulk_run; then
		coprocess_stop html_json
		if [ ${CREATED_JLOCK:-0} -eq 1 ]; then
			update_stats >/dev/null 2>&1 || :
		fi
	fi

	[ -n ${CLEANUP_HOOK} ] && ${CLEANUP_HOOK}

	if [ ${CREATED_JLOCK:-0} -eq 1 ]; then
		_jlock jlock
		rm -rf "${jlock}" 2>/dev/null || :
	fi
	rm -rf "${POUDRIERE_TMPDIR}" >/dev/null 2>&1 || :
}

build_url() {
	if [ -z "${URL_BASE}" ]; then
		setvar "$1" ""
		return 1
	fi
	setvar "$1" "${URL_BASE}/build.html?mastername=${MASTERNAME}&build=${BUILDNAME}"
}

log_url() {
	if [ -z "${URL_BASE}" ]; then
		setvar "$1" ""
		return 1
	fi
	setvar "$1" "${URL_BASE}/data/${MASTERNAME}/${BUILDNAME}/logs"
}

show_log_info() {
	local log build_url

	_log_path log
	msg "Logs: ${log}"
	build_url build_url && \
	    msg "WWW: ${build_url}"
	return 0
}

show_build_summary() {
	local status nbb nbf nbs nbi nbq ndone nbtobuild buildname
	local log now elapsed buildtime queue_width

	update_stats 2>/dev/null || return 0

	_bget nbq stats_queued 2>/dev/null || nbq=0
	_bget status status 2>/dev/null || status=unknown
	_bget nbf stats_failed 2>/dev/null || nbf=0
	_bget nbi stats_ignored 2>/dev/null || nbi=0
	_bget nbs stats_skipped 2>/dev/null || nbs=0
	_bget nbb stats_built 2>/dev/null || nbb=0
	ndone=$((nbb + nbf + nbi + nbs))
	nbtobuild=$((nbq - ndone))

	if [ ${nbq} -gt 9999 ]; then
		queue_width=5
	elif [ ${nbq} -gt 999 ]; then
		queue_width=4
	elif [ ${nbq} -gt 99 ]; then
		queue_width=3
	else
		queue_width=2
	fi

	_log_path log
	_bget buildname buildname 2>/dev/null || :
	now=$(clock -epoch)

	calculate_elapsed_from_log ${now} ${log} || return 1
	elapsed=${_elapsed_time}
	calculate_duration buildtime ${elapsed}

	printf "[${MASTERNAME}] [${buildname}] [${status}] \
Queued: %-${queue_width}d ${COLOR_SUCCESS}Built: %-${queue_width}d \
${COLOR_FAIL}Failed: %-${queue_width}d ${COLOR_SKIP}Skipped: \
%-${queue_width}d ${COLOR_IGNORE}Ignored: %-${queue_width}d${COLOR_RESET} \
Tobuild: %-${queue_width}d  Time: %s\n" \
	    ${nbq} ${nbb} ${nbf} ${nbs} ${nbi} ${nbtobuild} "${buildtime}"
}

siginfo_handler() {
	trappedinfo=1
	in_siginfo_handler=1
	[ "${POUDRIERE_BUILD_TYPE}" != "bulk" ] && return 0
	local status
	local now
	local j elapsed job_id_color
	local pkgname origin phase buildtime started
	local format_origin_phase format_phase
	local -

	set +e

	trap '' SIGINFO

	_bget status status 2>/dev/null || status=unknown
	if [ "${status}" = "index:" -o "${status#stopped:}" = "crashed:" ]; then
		enable_siginfo_handler
		return 0
	fi

	_bget nbq stats_queued 2>/dev/null || nbq=0
	if [ -z "${nbq}" ]; then
		enable_siginfo_handler
		return 0
	fi

	show_build_summary

	now=$(clock -monotonic)

	# Skip if stopping or starting jobs or stopped.
	if [ -n "${JOBS}" -a "${status#starting_jobs:}" = "${status}" \
	    -a "${status}" != "stopping_jobs:" -a -n "${MASTERMNT}" ] && \
	    ! status_is_stopped "${status}"; then
		for j in ${JOBS}; do
			# Ignore error here as the zfs dataset may not be cloned yet.
			_bget status ${j} status 2>/dev/null || :
			# Skip builders not started yet
			[ -z "${status}" ] && continue
			# Hide idle workers
			[ "${status}" = "idle:" ] && continue
			phase="${status%%:*}"
			status="${status#*:}"
			origin="${status%%:*}"
			status="${status#*:}"
			pkgname="${status%%:*}"
			status="${status#*:}"
			started="${status%%:*}"

			colorize_job_id job_id_color "${j}"

			# Must put colors in format
			format_origin_phase="\t[${job_id_color}%s${COLOR_RESET}]: ${COLOR_PORT}%-32s ${COLOR_PHASE}%-15s${COLOR_RESET} (%s)\n"
			format_phase="\t[${job_id_color}%s${COLOR_RESET}]: ${COLOR_PHASE}%15s${COLOR_RESET}\n"

			if [ -n "${pkgname}" ]; then
				elapsed=$((${now} - ${started}))
				calculate_duration buildtime "${elapsed}"
				printf "${format_origin_phase}" "${j}" \
				    "${origin}" "${phase}" ${buildtime}
			else
				printf "${format_phase}" "${j}" "${phase}"
			fi
		done
	fi

	show_log_info
	enable_siginfo_handler
}

jail_exists() {
	[ $# -ne 1 ] && eargs jail_exists jailname
	local jname=$1
	[ -d ${POUDRIERED}/jails/${jname} ] && return 0
	return 1
}

jail_runs() {
	[ $# -ne 1 ] && eargs jail_runs jname
	local jname=$1
	jls -j $jname >/dev/null 2>&1 && return 0
	return 1
}

porttree_list() {
	local name method mntpoint
	[ -d ${POUDRIERED}/ports ] || return 0
	for p in $(find ${POUDRIERED}/ports -type d -maxdepth 1 -mindepth 1 -print); do
		name=${p##*/}
		_pget mnt ${name} mnt 2>/dev/null || :
		_pget method ${name} method 2>/dev/null || :
		echo "${name} ${method:--} ${mnt}"
	done
}

porttree_exists() {
	[ $# -ne 1 ] && eargs porttree_exists portstree_name
	porttree_list |
		awk -v portstree_name=$1 '
		BEGIN { ret = 1 }
		$1 == portstree_name {ret = 0; }
		END { exit ret }
		' && return 0
	return 1
}

get_data_dir() {
	local data
	if [ -n "${POUDRIERE_DATA}" ]; then
		echo ${POUDRIERE_DATA}
		return
	fi

	if [ -z "${NO_ZFS}" ]; then
		data=$(zfs list -rt filesystem -H -o ${NS}:type,mountpoint ${ZPOOL}${ZROOTFS} 2>/dev/null |
		    awk '$1 == "data" { print $2; exit; }')
		if [ -n "${data}" ]; then
			echo "${data}"
			return
		fi
		# Manually created dataset may be missing type, set it and
		# don't add more child datasets.
		if zfs get mountpoint ${ZPOOL}${ZROOTFS}/data >/dev/null \
		    2>&1; then
			zfs set ${NS}:type=data ${ZPOOL}${ZROOTFS}/data
			zfs get -H -o value mountpoint ${ZPOOL}${ZROOTFS}/data
			return
		fi
		zfs create -p -o ${NS}:type=data \
			-o atime=off \
			-o mountpoint=${BASEFS}/data \
			${ZPOOL}${ZROOTFS}/data
		zfs create ${ZPOOL}${ZROOTFS}/data/.m
		zfs create -o compression=off ${ZPOOL}${ZROOTFS}/data/cache
		zfs create -o compression=lz4 ${ZPOOL}${ZROOTFS}/data/logs
		zfs create -o compression=off ${ZPOOL}${ZROOTFS}/data/packages
		zfs create -o compression=off ${ZPOOL}${ZROOTFS}/data/wrkdirs
	else
		mkdir -p "${BASEFS}/data"
	fi
	echo "${BASEFS}/data"
}

fetch_file() {
	[ $# -ne 2 ] && eargs fetch_file destination source
	fetch -p -o $1 $2 || fetch -p -o $1 $2 || err 1 "Failed to fetch from $2"
}

# Export handling is different in builtin vs external
if [ "$(type mktemp)" = "mktemp is a shell builtin" ]; then
	MKTEMP_BUILTIN=1
fi
# Wrap mktemp to put most tmpfiles in mnt/.p/tmp rather than system /tmp.
mktemp() {
	local ret

	if [ -z "${TMPDIR}" ]; then
		if [ -n "${MASTERMNT}" -a ${STATUS} -eq 1 ]; then
			local mnt
			_my_path mnt
			TMPDIR="${mnt}/.p/tmp"
			[ -d "${TMPDIR}" ] || unset TMPDIR
		else
			TMPDIR="${POUDRIERE_TMPDIR}"
		fi
	fi
	if [ -n "${MKTEMP_BUILTIN}" ]; then
		# No export needed here since TMPDIR is set above in scope.
		builtin mktemp "$@"
	else
		[ -n "${TMPDIR}" ] && export TMPDIR
		command mktemp "$@"
	fi
}

common_mtree() {
	[ $# -eq 1 ] || eargs common_mtree mtreefile
	local mtreefile="$1"
	local exclude

	cat > "${mtreefile}" <<EOF
./.npkg
./.p
./.poudriere-snap-*
.${HOME}/.ccache
./compat/linux/proc
./dev
./distfiles
./packages
./portdistfiles
./proc
.${PORTSDIR}
./usr/src
./var/db/freebsd-update
./var/db/ports
./wrkdirs
EOF
	for exclude in ${LOCAL_MTREE_EXCLUDES}; do
		echo "${exclude#.}" >> "${mtreefile}"
	done
}

markfs() {
	[ $# -lt 2 ] && eargs markfs name mnt path
	local name=$1
	local mnt="${2}"
	local path="$3"
	local fs="$(zfs_getfs ${mnt})"
	local dozfs=0
	local domtree=0
	local mtreefile
	local snapfile

	msg_n "Recording filesystem state for ${name}..."

	case "${name}" in
	clean) [ -n "${fs}" ] && dozfs=1 ;;
	prepkg)
		[ -n "${fs}" ] && dozfs=1
		# Only create prepkg mtree in ref
		# Everything else may need to snapshot
		if [ "${mnt##*/}" = "ref" ]; then
			domtree=1
		else
			domtree=0
		fi
		;;
	prebuild|prestage) domtree=1 ;;
	preinst) domtree=1 ;;
	esac

	if [ $dozfs -eq 1 ]; then
		# remove old snapshot if exists
		zfs destroy -r ${fs}@${name} 2>/dev/null || :
		rollback_file "${mnt}" "${name}" snapfile
		rm -f "${snapfile}" >/dev/null 2>&1 || :
		#create new snapshot
		zfs snapshot ${fs}@${name}
		# Mark that we are in this snapshot, which rollbackfs
		# will check for not existing when rolling back later.
		: > "${snapfile}"
	fi

	if [ $domtree -eq 0 ]; then
		echo " done"
		return 0
	fi
	mtreefile=${mnt}/.p/mtree.${name}exclude

	common_mtree ${mtreefile}
	case "${name}" in
		prebuild|prestage)
			cat >> ${mtreefile} <<-EOF
			./tmp
			./var/tmp
			EOF
			;;
		preinst)
			cat >> ${mnt}/.p/mtree.${name}exclude << EOF
./etc/group
./etc/make.conf
./etc/make.conf.bak
./etc/master.passwd
./etc/passwd
./etc/pwd.db
./etc/shells
./etc/spwd.db
./tmp
./var/db/pkg
./var/log
./var/mail
./var/run
./var/tmp
EOF
		;;
	esac
	( cd "${mnt}${path}" && mtree -X ${mnt}/.p/mtree.${name}exclude \
		-cn -k uid,gid,mode,size \
		-p . ) > ${mnt}/.p/mtree.${name}
	echo " done"
}

rm() {
	local arg

	for arg in "$@"; do
		[ "${arg}" = "/" ] && err 1 "Tried to rm /"
		[ "${arg%/}" = "/bin" ] && err 1 "Tried to rm /*"
	done

	command rm "$@"
}

# Handle relative path change needs
cd() {
	local ret

	ret=0
	command cd "$@" || ret=$?
	# Handle fixing relative paths
	if [ "${OLDPWD}" != "${PWD}" ]; then
		# Only change if it is relative
		if [ -n "${SHASH_VAR_PATH##/*}" ]; then
			_relpath "${OLDPWD}/${SHASH_VAR_PATH}" "${PWD}"
			SHASH_VAR_PATH="${_relpath}"
		fi
	fi
	return ${ret}
}

do_jail_mounts() {
	[ $# -ne 4 ] && eargs do_jail_mounts from mnt arch name
	local from="$1"
	local mnt="$2"
	local arch="$3"
	local name="$4"
	local devfspath="null zero random urandom stdin stdout stderr fd fd/* bpf* pts pts/*"
	local srcpath nullpaths nullpath

	# from==mnt is via jail -u

	# clone will inherit from the ref jail
	if [ ${mnt##*/} = "ref" ]; then
		mkdir -p ${mnt}/proc \
		    ${mnt}/dev \
		    ${mnt}/compat/linux/proc \
		    ${mnt}/usr/src
	fi

	# Mount some paths read-only from the ref-jail if possible.
	nullpaths="/rescue"
	if [ "${MUTABLE_BASE}" = "no" ]; then
		# Need to keep /usr/src and /usr/ports on their own.
		nullpaths="${nullpaths} /usr/bin /usr/include /usr/lib \
		    /usr/lib32 /usr/libdata /usr/libexec /usr/obj \
		    /usr/sbin /usr/share /usr/tests /boot /bin /sbin /lib \
		    /libexec"
		# Do a real copy for the ref jail since we need to modify
		# or create directories in them.
		if [ "${mnt##*/}" != "ref" ]; then
			nullpaths="${nullpaths} /etc"
		fi

	fi
	echo ${nullpaths} | tr ' ' '\n' | sed -e "s,^/,${mnt}/," | \
	    xargs mkdir -p
	for nullpath in ${nullpaths}; do
		[ -d "${from}${nullpath}" -a "${from}" != "${mnt}" ] && \
		    ${NULLMOUNT} -o ro "${from}${nullpath}" "${mnt}${nullpath}"
	done

	# Mount /usr/src into target if it exists and not overridden
	_jget srcpath ${name} srcpath 2>/dev/null || srcpath="${from}/usr/src"
	[ -d "${srcpath}" -a "${from}" != "${mnt}" ] && \
	    ${NULLMOUNT} -o ro ${srcpath} ${mnt}/usr/src

	mount -t devfs devfs ${mnt}/dev
	if [ ${JAILED} -eq 0 ]; then
		devfs -m ${mnt}/dev rule apply hide
		for p in ${devfspath} ; do
			devfs -m ${mnt}/dev/ rule apply path "${p}" unhide
		done
	fi

	[ "${USE_FDESCFS}" = "yes" ] && \
	    [ ${JAILED} -eq 0 -o "${PATCHED_FS_KERNEL}" = "yes" ] && \
	    mount -t fdescfs fdesc "${mnt}/dev/fd"
	[ "${USE_PROCFS}" = "yes" ] && \
	    mount -t procfs proc "${mnt}/proc"
	[ -z "${NOLINUX}" ] && \
	    [ "${arch}" = "i386" -o "${arch}" = "amd64" ] && \
	    [ -d "${mnt}/compat" ] && \
	    mount -t linprocfs linprocfs "${mnt}/compat/linux/proc"

	run_hook jail mount ${mnt}

	return 0
}

# Interactive test mode
enter_interactive() {
	local stopmsg

	if [ ${ALL} -ne 0 ]; then
		msg "(-a) Not entering interactive mode."
		return 0
	fi

	print_phase_header "Interactive"
	bset status "interactive:"

	msg "Installing packages"
	echo "PACKAGES=/packages" >> ${MASTERMNT}/etc/make.conf
	echo "127.0.0.1 ${MASTERNAME}" >> ${MASTERMNT}/etc/hosts

	# Skip for testport as it has already installed pkg in the ref jail.
	if [ "${SCRIPTPATH##*/}" != "testport.sh" ]; then
		# Install pkg-static so full pkg package can install
		ensure_pkg_installed force_extract || \
		    err 1 "Unable to extract pkg."
		# Install the selected pkg package
		injail env USE_PACKAGE_DEPENDS_ONLY=1 \
		    /usr/bin/make -C \
		    ${PORTSDIR}/$(injail /usr/bin/make \
		    -f ${PORTSDIR}/Mk/bsd.port.mk -V PKGNG_ORIGIN) \
		    PKG_BIN="${PKG_BIN}" install-package
	fi

	# Enable all selected ports and their run-depends
	for port in $(listed_ports); do
		# Install run-depends since this is an interactive test
		msg "Installing run-depends for ${COLOR_PORT}${port}"
		injail env USE_PACKAGE_DEPENDS_ONLY=1 \
		    /usr/bin/make -C ${PORTSDIR}/${port} run-depends ||
		    msg_warn "Failed to install ${COLOR_PORT}${port} run-depends"
		if [ -z "${POUDRIERE_INTERACTIVE_NO_INSTALL}" ]; then
			msg "Installing ${COLOR_PORT}${port}"
			# Only use PKGENV during install as testport will store
			# the package in a different place than dependencies
			injail env USE_PACKAGE_DEPENDS_ONLY=1 ${PKGENV} \
			    /usr/bin/make -C ${PORTSDIR}/${port} install-package ||
			    msg_warn "Failed to install ${COLOR_PORT}${port}"
		fi
	done

	# Create a pkg repo configuration, and disable FreeBSD
	msg "Installing local Pkg repository to ${LOCALBASE}/etc/pkg/repos"
	mkdir -p ${MASTERMNT}${LOCALBASE}/etc/pkg/repos
	cat > ${MASTERMNT}${LOCALBASE}/etc/pkg/repos/local.conf << EOF
FreeBSD: {
	enabled: no
}

local: {
	url: "file:///packages",
	enabled: yes
}
EOF

	if [ ${INTERACTIVE_MODE} -eq 1 ]; then
		msg "Entering interactive test mode. Type 'exit' when done."
		JNETNAME="n" injail_tty env -i TERM=${SAVED_TERM} \
		    /usr/bin/login -fp root || :
	elif [ ${INTERACTIVE_MODE} -eq 2 ]; then
		# XXX: Not tested/supported with bulk yet.
		msg "Leaving jail ${MASTERNAME}-n running, mounted at ${MASTERMNT} for interactive run testing"
		msg "To enter jail: jexec ${MASTERNAME}-n env -i TERM=\$TERM /usr/bin/login -fp root"
		stopmsg="-j ${JAILNAME}"
		[ -n "${SETNAME}" ] && stopmsg="${stopmsg} -z ${SETNAME}"
		[ -n "${PTNAME#default}" ] && stopmsg="${stopmsg} -p ${PTNAME}"
		msg "To stop jail: poudriere jail -k ${stopmsg}"
		CLEANED_UP=1
		return 0
	fi
	print_phase_footer
}

use_options() {
	[ $# -ne 2 ] && eargs use_options mnt optionsdir
	local mnt=$1
	local optionsdir=$2

	if [ "${optionsdir}" = "-" ]; then
		optionsdir="${POUDRIERED}/options"
	else
		optionsdir="${POUDRIERED}/${optionsdir}-options"
	fi
	[ -d "${optionsdir}" ] || return 1
	optionsdir=$(realpath ${optionsdir} 2>/dev/null)
	[ "${mnt##*/}" = "ref" ] && \
	    msg "Copying /var/db/ports from: ${optionsdir}"
	do_clone "${optionsdir}" "${mnt}/var/db/ports" || \
	    err 1 "Failed to copy OPTIONS directory"

	return 0
}

mount_packages() {
	local mnt

	_my_path mnt
	${NULLMOUNT} "$@" ${PACKAGES} \
		${mnt}/packages ||
		err 1 "Failed to mount the packages directory "
}

do_portbuild_mounts() {
	[ $# -lt 3 ] && eargs do_portbuild_mounts mnt jname ptname setname
	local mnt=$1
	local jname=$2
	local ptname=$3
	local setname=$4
	local portsdir
	local optionsdir

	# clone will inherit from the ref jail
	if [ ${mnt##*/} = "ref" ]; then
		mkdir -p "${mnt}${PORTSDIR}" \
		    "${mnt}/wrkdirs" \
		    "${mnt}/${LOCALBASE:-/usr/local}" \
		    "${mnt}/distfiles" \
		    "${mnt}/packages" \
		    "${mnt}/.npkg" \
		    "${mnt}/var/db/ports" \
		    "${mnt}${HOME}/.ccache"
	fi
	[ ${TMPFS_DATA} -eq 1 -o ${TMPFS_ALL} -eq 1 ] &&
	    mnt_tmpfs data "${mnt}/.p"

	mkdir -p "${mnt}/.p/tmp"

	[ -d "${CCACHE_DIR:-/nonexistent}" ] &&
		${NULLMOUNT} ${CCACHE_DIR} ${mnt}${HOME}/.ccache
	[ -n "${MFSSIZE}" ] && mdmfs -t -S -o async -s ${MFSSIZE} md ${mnt}/wrkdirs
	[ ${TMPFS_WRKDIR} -eq 1 ] && mnt_tmpfs wrkdir ${mnt}/wrkdirs
	# Only show mounting messages once, not for every builder
	if [ ${mnt##*/} = "ref" ]; then
		[ -d "${CCACHE_DIR}" ] &&
			msg "Mounting ccache from: ${CCACHE_DIR}"
		msg "Mounting packages from: ${PACKAGES_ROOT}"
	fi

	_pget portsdir ${ptname} mnt
	[ -d ${portsdir}/ports ] && portsdir=${portsdir}/ports
	${NULLMOUNT} -o ro ${portsdir} ${mnt}${PORTSDIR} ||
		err 1 "Failed to mount the ports directory "
	mount_packages -o ro
	${NULLMOUNT} ${DISTFILES_CACHE} ${mnt}/distfiles ||
		err 1 "Failed to mount the distfiles cache directory"

	# Copy in the options for the ref jail, but just ro nullmount it
	# in builders.
	if [ "${mnt##*/}" = "ref" ]; then
		[ ${TMPFS_DATA} -eq 1 -o ${TMPFS_ALL} -eq 1 ] && \
		    mnt_tmpfs config "${mnt}/var/db/ports"
		optionsdir="${MASTERNAME}"
		[ -n "${setname}" ] && optionsdir="${optionsdir} ${jname}-${setname}"
		optionsdir="${optionsdir} ${jname}-${ptname} ${setname} ${ptname} ${jname} -"

		for opt in ${optionsdir}; do
			use_options ${mnt} ${opt} && break || continue
		done
	else
		${NULLMOUNT} -o ro ${MASTERMNT}/var/db/ports \
		    ${mnt}/var/db/ports || \
		    err 1 "Failed to mount the options directory"
	fi

	return 0
}

# Convert the repository to the new format of links
# so that an atomic update can be done at the end
# of the build.
# This is done at the package repo level instead of the parent
# dir in DATA/packages because someone may have created a separate
# ZFS dataset / NFS mount for each dataset. Avoid cross-device linking.
convert_repository() {
	local pkgdir

	msg "Converting package repository to new format"

	pkgdir=.real_$(clock -epoch)
	mkdir ${PACKAGES}/${pkgdir}

	# Move all top-level dirs into .real
	find ${PACKAGES}/ -mindepth 1 -maxdepth 1 -type d ! -name ${pkgdir} |
	    xargs -J % mv % ${PACKAGES}/${pkgdir}
	# Symlink them over through .latest
	find ${PACKAGES}/${pkgdir} -mindepth 1 -maxdepth 1 -type d \
	    ! -name ${pkgdir} | while read directory; do
		dirname=${directory##*/}
		ln -s .latest/${dirname} ${PACKAGES}/${dirname}
	done

	# Now move+symlink any files in the top-level
	find ${PACKAGES}/ -mindepth 1 -maxdepth 1 -type f |
	    xargs -J % mv % ${PACKAGES}/${pkgdir}
	find ${PACKAGES}/${pkgdir} -mindepth 1 -maxdepth 1 -type f |
	    while read file; do
		fname=${file##*/}
		ln -s .latest/${fname} ${PACKAGES}/${fname}
	done

	# Setup current symlink which is how the build will atomically finish
	ln -s ${pkgdir} ${PACKAGES}/.latest
}

stash_packages() {

	PACKAGES_ROOT=${PACKAGES}

	[ "${ATOMIC_PACKAGE_REPOSITORY}" = "yes" ] || return 0

	[ -L ${PACKAGES}/.latest ] || convert_repository

	if [ -d ${PACKAGES}/.building ]; then
		# If the .building directory is still around, use it. The
		# previous build may have failed, but all of the successful
		# packages are still worth keeping for this build.
		msg "Using packages from previously failed build"
	else
		msg "Stashing existing package repository"

		# Use a linked shadow directory in the package root, not
		# in the parent directory as the user may have created
		# a separate ZFS dataset or NFS mount for each package
		# set; Must stay on the same device for linking.

		mkdir -p ${PACKAGES}/.building
		# hardlink copy all top-level directories
		find ${PACKAGES}/.latest/ -mindepth 1 -maxdepth 1 -type d \
		    ! -name .building | xargs -J % cp -al % ${PACKAGES}/.building

		# Copy all top-level files to avoid appending
		# to real copy in pkg-repo, etc.
		find ${PACKAGES}/.latest/ -mindepth 1 -maxdepth 1 -type f |
		    xargs -J % cp -a % ${PACKAGES}/.building
	fi

	# From this point forward, only work in the shadow
	# package dir
	PACKAGES=${PACKAGES}/.building
}

commit_packages() {
	local pkgdir_old pkgdir_new stats_failed

	[ "${ATOMIC_PACKAGE_REPOSITORY}" = "yes" ] || return 0
	if [ "${COMMIT_PACKAGES_ON_FAILURE}" = "no" ] &&
	    _bget stats_failed stats_failed && [ ${stats_failed} -gt 0 ]; then
		msg_warn "Not committing packages to repository as failures were encountered"
		return 0
	fi

	msg "Committing packages to repository"
	bset status "committing:"

	# Find any new top-level files not symlinked yet. This is
	# mostly incase pkg adds a new top-level repo or the ports framework
	# starts creating a new directory
	find ${PACKAGES}/ -mindepth 1 -maxdepth 1 ! -name '.*' |
	    while read path; do
		name=${path##*/}
		[ ! -L "${PACKAGES_ROOT}/${name}" ] || continue
		if [ -e "${PACKAGES_ROOT}/${name}" ]; then
			case "${name}" in
			meta.txz|digests.txz|packagesite.txz|All|Latest)
				# Auto fix pkg-owned files
				rm -f "${PACKAGES_ROOT}/${name}"
				;;
			*)
				msg_error "${PACKAGES_ROOT}/${name}
shadows repository file in .latest/${name}. Remove the top-level one and
symlink to .latest/${name}"
				continue
				;;
			esac
		fi
		ln -s .latest/${name} ${PACKAGES_ROOT}/${name}
	done

	pkgdir_old=$(realpath ${PACKAGES_ROOT}/.latest 2>/dev/null || :)

	# Rename shadow dir to a production name
	pkgdir_new=.real_$(clock -epoch)
	mv ${PACKAGES_ROOT}/.building ${PACKAGES_ROOT}/${pkgdir_new}

	# XXX: Copy in packages that failed to build

	# Switch latest symlink to new build
	PACKAGES=${PACKAGES_ROOT}/.latest
	ln -s ${pkgdir_new} ${PACKAGES_ROOT}/.latest_new
	rename ${PACKAGES_ROOT}/.latest_new ${PACKAGES}

	# Look for broken top-level links and remove them, if they reference
	# the old directory
	find -L ${PACKAGES_ROOT}/ -mindepth 1 -maxdepth 1 ! -name '.*' -type l |
	    while read path; do
		link=$(readlink ${path})
		# Skip if link does not reference inside latest
		[ "${link##.latest}" != "${link}" ] || continue
		rm -f ${path}
	done


	msg "Removing old packages"

	if [ "${KEEP_OLD_PACKAGES}" = "yes" ]; then
		keep_cnt=$((${KEEP_OLD_PACKAGES_COUNT} + 1))
		find ${PACKAGES_ROOT}/ -type d -mindepth 1 -maxdepth 1 \
		    -name '.real_*' | sort -dr |
		    sed -n "${keep_cnt},\$p" |
		    xargs rm -rf 2>/dev/null || :
	else
		# Remove old and shadow dir
		[ -n "${pkgdir_old}" ] && rm -rf ${pkgdir_old} 2>/dev/null || :
	fi
}

show_build_results() {
	local failed built ignored skipped nbbuilt nbfailed nbignored nbskipped

	failed=$(bget ports.failed | awk '{print $1 ":" $3 }' | xargs echo)
	failed=$(bget ports.failed | \
	    awk -v color_phase="${COLOR_PHASE}" \
	    -v color_port="${COLOR_PORT}" \
	    '{print $1 ":" color_phase $3 color_port }' | xargs echo)
	built=$(bget ports.built | awk '{print $1}' | xargs echo)
	ignored=$(bget ports.ignored | awk '{print $1}' | xargs echo)
	skipped=$(bget ports.skipped | awk '{print $1}' | sort -u | xargs echo)
	_bget nbbuilt stats_built
	_bget nbfailed stats_failed
	_bget nbignored stats_ignored
	_bget nbskipped stats_skipped

	[ $nbbuilt -gt 0 ] && COLOR_ARROW="${COLOR_SUCCESS}" \
	    msg "${COLOR_SUCCESS}Built ports: ${COLOR_PORT}${built}"
	[ $nbfailed -gt 0 ] && COLOR_ARROW="${COLOR_FAIL}" \
	    msg "${COLOR_FAIL}Failed ports: ${COLOR_PORT}${failed}"
	[ $nbskipped -gt 0 ] && COLOR_ARROW="${COLOR_SKIP}" \
	    msg "${COLOR_SKIP}Skipped ports: ${COLOR_PORT}${skipped}"
	[ $nbignored -gt 0 ] && COLOR_ARROW="${COLOR_IGNORE}" \
	    msg "${COLOR_IGNORE}Ignored ports: ${COLOR_PORT}${ignored}"

	show_build_summary
	show_log_info

	return 0
}

write_usock() {
	[ $# -gt 1 ] || eargs write_usock socket msg
	local socket="$1"
	shift
	nc -U "${socket}" <<- EOF
	$@
	EOF
}

# If running as non-root, redirect this command to queue and exit
maybe_run_queued() {
	[ $(/usr/bin/id -u) -eq 0 ] && return 0
	local this_command

	# If poudriered not running then the command cannot be
	# satisfied.
	/usr/sbin/service poudriered onestatus >/dev/null 2>&1 || \
	    err 1 "This command requires root or poudriered running"

	this_command="${SCRIPTPATH##*/}"
	this_command="${this_command%.sh}"

	write_usock ${QUEUE_SOCKET} command: "${this_command}", arguments: "$@"
	exit
}

get_host_arch() {
	[ $# -eq 1 ] || eargs get_host_arch var_return
	local var_return="$1"
	local _arch

	_arch="$(uname -m).$(uname -p)"
	# If TARGET=TARGET_ARCH trim it away and just use TARGET_ARCH
	[ "${_arch%.*}" = "${_arch#*.}" ] && _arch="${_arch#*.}"
	setvar "${var_return}" "${_arch}"
}

check_emulation() {
	[ $# -eq 2 ] || eargs check_emulation real_arch wanted_arch
	local real_arch="${1}"
	local wanted_arch="${2}"

	if need_emulation "${wanted_arch}"; then
		msg "Cross-building ports for ${wanted_arch} on ${real_arch} requires QEMU"
		[ -x "${BINMISC}" ] || \
		    err 1 "Cannot find ${BINMISC}. Install ${BINMISC} and restart"
		EMULATOR=$(${BINMISC} lookup ${wanted_arch#*.} 2>/dev/null | \
		    awk '/interpreter:/ {print $2}')
		[ -x "${EMULATOR}" ] || \
		    err 1 "You need to setup an emulator with binmiscctl(8) for ${wanted_arch#*.}"
		export QEMU_EMULATING=1
	fi
}

need_emulation() {
	[ $# -eq 1 ] || eargs need_emulation wanted_arch
	local wanted_arch="$1"
	local target_arch

	# kern.supported_archs is a list of TARGET_ARCHs.
	target_arch="${wanted_arch#*.}"

	# Check the list of supported archs from the kernel.
	# DragonFly does not have kern.supported_archs, fallback to
	# uname -m (advised by dillon)
	if { sysctl -n kern.supported_archs 2>/dev/null || uname -m; } | \
	    grep -qw "${target_arch}"; then
		return 1
	else
		# Returning 1 means no emulation required.
		return 0
	fi
}

need_cross_build() {
	[ $# -eq 2 ] || eargs need_cross_build real_arch wanted_arch
	local real_arch="$1"
	local wanted_arch="$2"

	# Check TARGET=i386 not TARGET_ARCH due to pc98/i386
	[ "${wanted_arch%.*}" = "i386" -a "${real_arch}" = "amd64" ] || \
	    [ "${wanted_arch#*.}" = "powerpc" -a \
	    "${real_arch#*.}" = "powerpc64" ] || \
	    need_emulation "${wanted_arch}"
}

_jlock() {
	setvar "$1" "/var/run/poudriere/poudriere.${MASTERNAME}.lock"
}

lock_jail() {
	local jlock jlockf jlockpid

	_jlock jlock
	jlockf="${jlock}/pid"
	mkdir -p /var/run/poudriere >/dev/null 2>&1 || :
	# Ensure no other processes are trying to start this jail
	if ! mkdir "${jlock}" 2>/dev/null; then
		if [ -d "${jlock}" ]; then
			jlockpid=
			if [ -f "${jlockf}" ]; then
				if locked_mkdir 5 "${jlock}.pid"; then
					read jlockpid < "${jlockf}" || :
					rmdir "${jlock}.pid"
				else
					# Something went wrong, just try again
					lock_jail
					return
				fi
			fi
			if [ -n "${jlockpid}" ]; then
				if ! kill -0 ${jlockpid} >/dev/null 2>&1; then
					# The process is dead;
					# the lock is stale
					rm -rf "${jlock}"
					# Try to get the lock again
					lock_jail
					return
				else
					# The lock is currently held
					err 1 "jail currently starting: ${MASTERNAME}"
				fi
			else
				# This shouldn't happen due to the
				# use of locking on the file, just
				# blow it away and try again.
				rm -rf "${jlock}"
				lock_jail
				return
			fi
		else
			err 1 "Unable to create jail lock ${jlock}"
		fi
	else
		# We're safe to start the jail and to later remove the lock.
		if locked_mkdir 5 "${jlock}.pid"; then
			CREATED_JLOCK=1
			echo "$$" > "${jlock}/pid"
			rmdir "${jlock}.pid"
			return 0
		else
			# Something went wrong, just try again
			lock_jail
			return
		fi
	fi
}

setup_ccache() {
	[ $# -eq 1 ] || eargs setup_ccache tomnt
	local tomnt="$1"
	local ccacheprefix

	if [ -d "${CCACHE_DIR:-/nonexistent}" ]; then
		cat >> "${tomnt}/etc/make.conf" <<-EOF
		WITH_CCACHE_BUILD=yes
		CCACHE_DIR=${HOME}/.ccache
		EOF
	fi
	# A static host version may have been requested.
	if [ -n "${CCACHE_STATIC_PREFIX}" ] && \
	    [ -x "${CCACHE_STATIC_PREFIX}/bin/ccache" ]; then
		file "${CCACHE_STATIC_PREFIX}/bin/ccache" | \
		    grep -q "statically linked" || \
		    err 1 "CCACHE_STATIC_PREFIX used but ${CCACHE_STATIC_PREFIX}/bin/ccache is not static."
		ccacheprefix=/ccache
		mkdir -p "${tomnt}${ccacheprefix}/libexec/ccache/world" \
		    "${tomnt}${ccacheprefix}/bin"
		msg "Copying host static ccache from ${CCACHE_STATIC_PREFIX}/bin/ccache"
		cp -f "${CCACHE_STATIC_PREFIX}/bin/ccache" \
		    "${CCACHE_STATIC_PREFIX}/bin/ccache-update-links" \
		    "${tomnt}${ccacheprefix}/bin/"
		cp -f "${CCACHE_STATIC_PREFIX}/libexec/ccache/world/ccache" \
		    "${tomnt}${ccacheprefix}/libexec/ccache/world/ccache"
		# Tell the ports framework that we don't need it to add
		# a BUILD_DEPENDS on everything for ccache.
		# Also set it up to look in our ccacheprefix location for the
		# wrappers.
		cat >> "${tomnt}/etc/make.conf" <<-EOF
		NO_CCACHE_DEPEND=1
		CCACHE_WRAPPER_PATH=	${ccacheprefix}/libexec/ccache
		EOF
		# Link the wrapper update script to /sbin so that
		# any package trying to update the links will find it
		# rather than an actual ccache package in the jail.
		ln -fs "../${ccacheprefix}/bin/ccache-update-links" \
		    "${tomnt}/sbin/ccache-update-links"
		# Fix the wrapper update script to always make the links
		# in the new prefix.
		sed -i '' -e "s,^\(PREFIX\)=.*,\1=\"${ccacheprefix}\"," \
		    "${tomnt}${ccacheprefix}/bin/ccache-update-links"
		# Create base compiler links
		injail "${ccacheprefix}/bin/ccache-update-links"
	fi
}

jail_start() {
	[ $# -lt 2 ] && eargs jail_start name ptname setname
	local name=$1
	local ptname=$2
	local setname=$3
	local portsdir
	local arch host_arch
	local mnt
	local needfs="${NULLFSREF}"
	local needkld kldpair kld kldmodname
	local tomnt
	local portbuild_uid

	lock_jail

	if [ -n "${MASTERMNT}" ]; then
		tomnt="${MASTERMNT}"
	else
		_mastermnt tomnt
	fi
	_pget portsdir ${ptname} mnt
	_jget arch ${name} arch
	get_host_arch host_arch
	_jget mnt ${name} mnt

	# Protect ourselves from OOM
	madvise_protect $$ || :

	PORTSDIR="/usr/ports"

	JAIL_OSVERSION=$(awk '/\#define __FreeBSD_version/ { print $3 }' "${mnt}/usr/include/sys/param.h")

	[ ${JAIL_OSVERSION} -lt 900000 ] && needkld="${needkld} sem"

	if [ "${DISTFILES_CACHE}" != "no" -a ! -d "${DISTFILES_CACHE}" ]; then
		err 1 "DISTFILES_CACHE directory does not exist. (c.f.  poudriere.conf)"
	fi
	[ ${TMPFS_ALL} -ne 1 ] && [ $(sysctl -n kern.securelevel) -ge 1 ] && \
	    err 1 "kern.securelevel >= 1. Poudriere requires no securelevel to be able to handle schg flags. USE_TMPFS=all can override this."
	[ "${name#*.*}" = "${name}" ] ||
		err 1 "The jail name cannot contain a period (.). See jail(8)"
	[ "${ptname#*.*}" = "${ptname}" ] ||
		err 1 "The ports name cannot contain a period (.). See jail(8)"
	[ "${setname#*.*}" = "${setname}" ] ||
		err 1 "The set name cannot contain a period (.). See jail(8)"

	if [ -z "${NOLINUX}" ]; then
		if [ "${arch}" = "i386" -o "${arch}" = "amd64" ]; then
			needfs="${needfs} linprocfs"
			needkld="${needkld} linuxelf:linux"
			if [ "${arch}" = "amd64" ] && \
			    [ ${HOST_OSVERSION} -ge 1002507 ]; then
				needkld="${needkld} linux64elf:linux64"
			fi
		fi
	fi
	[ "${USE_TMPFS}" != "no" ] && needfs="${needfs} tmpfs"
	[ "${USE_PROCFS}" = "yes" ] && needfs="${needfs} procfs"
	[ "${USE_FDESCFS}" = "yes" ] && \
	    [ ${JAILED} -eq 0 -o "${PATCHED_FS_KERNEL}" = "yes" ] && \
	    needfs="${needfs} fdescfs"
	for fs in ${needfs}; do
		if ! lsvfs $fs >/dev/null 2>&1; then
			if [ $JAILED -eq 0 ]; then
				kldload $fs || err 1 "Required kernel module '${fs}' not found"
			else
				err 1 "please load the $fs module on host using \"kldload $fs\""
			fi
		fi
	done
	for kldpair in ${needkld}; do
		kldmodname="${kldpair%:*}"
		kld="${kldpair#*:}"
		if ! kldstat -q -m "${kldmodname}" ; then
			if [ $JAILED -eq 0 ]; then
				kldload "${kld}" || \
				    err 1 "Required kernel module '${kld}' not found"
			else
				err 1 "Please load the ${kld} module on the host using \"kldload ${kld}\""
			fi
		fi
	done
	jail_exists ${name} || err 1 "No such jail: ${name}"
	jail_runs ${MASTERNAME} && err 1 "jail already running: ${MASTERNAME}"
	check_emulation "${host_arch}" "${arch}"

	# Block the build dir from being traversed by non-root to avoid
	# system blowup due to all of the extra mounts
	mkdir -p ${MASTERMNT%/ref}
	chmod 0755 ${POUDRIERE_DATA}/.m
	chmod 0711 ${MASTERMNT%/ref}

	export HOME=/root
	export USER=root
	[ -z "${NO_FORCE_PACKAGE}" ] && export FORCE_PACKAGE=yes
	[ -z "${NO_PACKAGE_BUILDING}" ] && export PACKAGE_BUILDING=yes

	# Only set STATUS=1 if not turned off
	# jail -s should not do this or jail will stop on EXIT
	[ ${SET_STATUS_ON_START-1} -eq 1 ] && export STATUS=1
	msg_n "Creating the reference jail..."
	if [ ${USE_CACHED} = "yes" ]; then
		export CACHESOCK=${MASTERMNT%/ref}/cache.sock
		export CACHEPID=${MASTERMNT%/ref}/cache.pid
		cached -s /${MASTERNAME} -p ${CACHEPID} -n ${MASTERNAME}
	fi
	clonefs ${mnt} ${tomnt} clean
	echo " done"

	if [ ${JAIL_OSVERSION} -gt ${HOST_OSVERSION} ]; then
		msg_warn "!!! Jail is newer than host. (Jail: ${JAIL_OSVERSION}, Host: ${HOST_OSVERSION}) !!!"
		msg_warn "This is not supported."
		msg_warn "Host kernel must be same or newer than jail."
		msg_warn "Expect build failures."
		sleep 1
	fi

	msg "Mounting system devices for ${MASTERNAME}"
	do_jail_mounts "${mnt}" "${tomnt}" ${arch} ${name}

	PACKAGES=${POUDRIERE_DATA}/packages/${MASTERNAME}

	[ -d "${portsdir}/ports" ] && portsdir="${portsdir}/ports"
	msg "Mounting ports/packages/distfiles"

	mkdir -p ${PACKAGES}/
	was_a_bulk_run && stash_packages

	do_portbuild_mounts ${tomnt} ${name} ${ptname} ${setname}

	# Handle special QEMU needs.
	if [ ${QEMU_EMULATING} -eq 1 ]; then
		# QEMU is really slow. Extend the time significantly.
		msg "Raising MAX_EXECUTION_TIME and NOHANG_TIME for QEMU"
		MAX_EXECUTION_TIME=864000
		NOHANG_TIME=72000
		# Setup native-xtools overrides.
		cat >> "${tomnt}/etc/make.conf" <<-EOF
		.sinclude "/etc/make.nxb.conf"
		EOF
		# Copy in the latest version of the emulator.
		msg "Copying latest version of the emulator from: ${EMULATOR}"
		mkdir -p "${tomnt}${EMULATOR%/*}"
		cp -f "${EMULATOR}" "${tomnt}${EMULATOR}"
	fi
	# Handle special ARM64 needs
	if [ "${arch#*.}" = "aarch64" ] && ! [ -f "${tomnt}/usr/bin/ld" ]; then
		if [ -f /usr/local/aarch64-freebsd/bin/ld ]; then
			msg "Copying aarch64-binutils ld from /usr/local/aarch64-freebsd/bin/ld"
			cp -f /usr/local/aarch64-freebsd/bin/ld \
			    "${tomnt}/usr/bin/ld"
			if [ -d "${tomnt}/nxb-bin/usr/bin" ]; then
				# Create a symlink to satisfy the LD in
				# make.nxb.conf and because running
				# /nxb-bin/usr/bin/cc defaults to looking for
				# /nxb-bin/usr/bin/ld.
				ln -f "${tomnt}/usr/bin/ld" \
				    "${tomnt}/nxb-bin/usr/bin/ld"
			fi
		else
			err 1 "Arm64 requires aarch64-binutils to be installed."
		fi
	fi

	cat >> "${tomnt}/etc/make.conf" <<-EOF
	USE_PACKAGE_DEPENDS=yes
	BATCH=yes
	WRKDIRPREFIX=/wrkdirs
	PORTSDIR=${PORTSDIR}
	PACKAGES=/packages
	DISTDIR=/distfiles
	EOF

	setup_makeconf ${tomnt}/etc/make.conf ${name} ${ptname} ${setname}
	load_blacklist ${name} ${ptname} ${setname}

	[ -n "${RESOLV_CONF}" ] && cp -v "${RESOLV_CONF}" "${tomnt}/etc/"
	msg "Starting jail ${MASTERNAME}"
	jstart
	if [ ${CREATED_JLOCK:-0} -eq 1 ]; then
		_jlock jlock
		rm -rf "${jlock}" 2>/dev/null || :
	fi
	injail id >/dev/null 2>&1 || \
	    err 1 "Unable to execute id(1) in jail. Emulation or ABI wrong."
	portbuild_uid=$(injail id -u ${PORTBUILD_USER} 2>/dev/null || :)
	if [ -z "${portbuild_uid}" ]; then
		msg_n "Creating user/group ${PORTBUILD_USER}"
		injail pw groupadd ${PORTBUILD_USER} -g ${PORTBUILD_UID} || \
		err 1 "Unable to create group ${PORTBUILD_USER}"
		injail pw useradd ${PORTBUILD_USER} -u ${PORTBUILD_UID} -d /nonexistent -c "Package builder" || \
		err 1 "Unable to create user ${PORTBUILD_USER}"
		echo " done"
	else
		PORTBUILD_UID=${portbuild_uid}
		PORTBUILD_GID=$(injail id -g ${PORTBUILD_USER})
	fi
	injail service ldconfig start >/dev/null || \
	    err 1 "Failed to set ldconfig paths."

	setup_ccache "${tomnt}"

	# We want this hook to run before any make -V executions in case
	# a hook modifies ports or the jail somehow relevant.
	run_hook jail start

	# Suck in ports environment to avoid redundant fork/exec for each
	# child.
	if [ -f "${tomnt}${PORTSDIR}/Mk/Scripts/ports_env.sh" ]; then
		local make

		if [ -x "${tomnt}/usr/bin/bmake" ]; then
			make=/usr/bin/bmake
		else
			make=/usr/bin/make
		fi
		{
			echo "#### /usr/ports/Mk/Scripts/ports_env.sh ####"
			injail env \
			    SCRIPTSDIR=${PORTSDIR}/Mk/Scripts \
			    PORTSDIR=${PORTSDIR} \
			    MAKE=${make} \
			    /bin/sh ${PORTSDIR}/Mk/Scripts/ports_env.sh | \
			    grep '^export [^;&]*' | \
			    sed -e 's,^export ,,' -e 's,=",=,' -e 's,"$,,'
			echo "#### Misc Poudriere ####"
			# This is not set by ports_env as older Poudriere
			# would not handle it right.
			echo "GID=0"
		} >> ${tomnt}/etc/make.conf
	fi
	# Determine if the ports tree supports SELECTED_OPTIONS from
	# r403743
	if [ -f "${tomnt}${PORTSDIR}/Mk/bsd.options.mk" ] && \
	    grep -m1 -q SELECTED_OPTIONS \
	    "${tomnt}${PORTSDIR}/Mk/bsd.options.mk"; then
		PORTS_HAS_SELECTED_OPTIONS=1
	else
		# Fallback on pretty-print-config.
		PORTS_HAS_SELECTED_OPTIONS=0
		# XXX: If we know we can use bmake then this would work
		# make _SELECTED_OPTIONS='${ALL_OPTIONS:@opt@${PORT_OPTIONS:M${opt}}@} ${MULTI GROUP SINGLE RADIO:L:@otype@${OPTIONS_${otype}:@m@${OPTIONS_${otype}_${m}:@opt@${PORT_OPTIONS:M${opt}}@}@}@}' -V _SELECTED_OPTIONS:O
	fi

	PKG_EXT="txz"
	PKG_BIN="/.p/pkg-static"
	PKG_ADD="${PKG_BIN} add"
	PKG_DELETE="${PKG_BIN} delete -y -f"
	PKG_VERSION="${PKG_BIN} version"

	[ -n "${PKG_REPO_SIGNING_KEY}" ] &&
		! [ -f "${PKG_REPO_SIGNING_KEY}" ] &&
		err 1 "PKG_REPO_SIGNING_KEY defined but the file is missing."

	return 0
}

load_blacklist() {
	[ $# -lt 2 ] && eargs load_blacklist name ptname setname
	local name=$1
	local ptname=$2
	local setname=$3
	local bl b bfile

	bl="- ${setname} ${ptname} ${name} ${name}-${ptname}"
	[ -n "${setname}" ] && bl="${bl} ${name}-${setname} \
		${name}-${ptname}-${setname}"
	# If emulating always load a qemu-blacklist as it has special needs.
	[ ${QEMU_EMULATING} -eq 1 ] && bl="${bl} qemu"
	for b in ${bl} ; do
		if [ "${b}" = "-" ]; then
			unset b
		fi
		bfile=${b:+${b}-}blacklist
		[ -f ${POUDRIERED}/${bfile} ] || continue
		for port in $(grep -h -v -E '(^[[:space:]]*#|^[[:space:]]*$)' \
		    ${POUDRIERED}/${bfile} | sed -e 's|[[:space:]]*#.*||'); do
			case " ${BLACKLIST} " in
			*\ ${port}\ *) continue;;
			esac
			msg_warn "Blacklisting (from ${POUDRIERED}/${bfile}): ${COLOR_PORT}${port}"
			BLACKLIST="${BLACKLIST} ${port}"
		done
	done
}

setup_makeconf() {
	[ $# -lt 3 ] && eargs setup_makeconf dst_makeconf name ptname setname
	local dst_makeconf=$1
	local name=$2
	local ptname=$3
	local setname=$4
	local makeconf opt
	local arch host_arch

	# The jail may be empty for poudriere-options.
	if [ -n "${name}" ]; then
		_jget arch "${name}" arch
		get_host_arch host_arch

		if need_cross_build "${host_arch}" "${arch}"; then
			cat >> "${dst_makeconf}" <<-EOF
			MACHINE=${arch%.*}
			MACHINE_ARCH=${arch#*.}
			ARCH=\${MACHINE_ARCH}
			EOF
		fi
	fi

	makeconf="- ${setname} ${ptname} ${name} ${name}-${ptname}"
	[ -n "${setname}" ] && makeconf="${makeconf} ${name}-${setname} \
		    ${name}-${ptname}-${setname}"
	for opt in ${makeconf}; do
		append_make ${opt} ${dst_makeconf}
	done

	# We will handle DEVELOPER for testing when appropriate
	if grep -q '^DEVELOPER=' ${dst_makeconf}; then
		msg_warn "DEVELOPER=yes ignored from make.conf. Use 'bulk -t' or 'testport' for testing instead."
		sed -i '' '/^DEVELOPER=/d' ${dst_makeconf}
	fi
}

include_poudriere_confs() {
	local files file flag args_hack

	# Spy on cmdline arguments so this function is not needed in
	# every new sub-command file, which could lead to missing it.
	args_hack=$(echo " $@"|grep -Eo -- ' -[^ ]*([jpz]) ?([^ ]*)'|tr '\n' ' '|sed -Ee 's, -[^ ]*([jpz]) ?([^ ]*),-\1 \2,g')
	set -- ${args_hack}
	while getopts "j:p:z:" flag; do
		case ${flag} in
			j) jail="${OPTARG}" ;;
			p) ptname="${OPTARG}" ;;
			z) setname="${OPTARG}" ;;
			*) ;;
		esac
	done

	files="${setname} ${ptname} ${jail}"
	[ -n "${jail}" -a -n "${ptname}" ] && \
	    files="${files} ${jail}-${ptname}"
	[ -n "${jail}" -a -n "${setname}" ] && \
	    files="${files} ${jail}-${setname}"
	[ -n "${jail}" -a -n "${setname}" -a -n "${ptname}" ] && \
	    files="${files} ${jail}-${ptname}-${setname}"
	for file in ${files}; do
		file="${POUDRIERED}/${file}-poudriere.conf"
		[ -r "${file}" ] && . "${file}"
	done

	return 0
}

jail_stop() {
	[ $# -ne 0 ] && eargs jail_stop
	local last_status

	run_hook jail stop

	# Make sure CWD is not inside the jail or MASTERMNT/.p, which may
	# cause EBUSY from umount.
	cd /

	jstop || :
	stop_builders >/dev/null || :
	if [ ${USE_CACHED} = "yes" ]; then
		pkill -15 -F ${CACHEPID} >/dev/null 2>&1 || :
	fi
	msg "Unmounting file systems"
	destroyfs ${MASTERMNT} jail || :
	rm -rfx ${MASTERMNT}/../
	export STATUS=0

	# Don't override if there is a failure to grab the last status.
	_bget last_status status 2>/dev/null || :
	[ -n "${last_status}" ] && bset status "stopped:${last_status}" \
	    2>/dev/null || :
}

jail_cleanup() {
	local wait_pids

	[ -n "${CLEANED_UP}" ] && return 0
	msg "Cleaning up"

	# Only bother with this if using jails as this may be being ran
	# from queue.sh or daemon.sh, etc.
	if [ -n "${MASTERMNT}" -a -n "${MASTERNAME}" ] && was_a_jail_run; then
		# If this is a builder, don't cleanup, the master will handle that.
		if [ -n "${MY_JOBID}" ]; then
			if [ -n "${PKGNAME}" ]; then
				clean_pool "${PKGNAME}" "" "failed" || :
			fi
			return 0
		fi

		if [ -d ${MASTERMNT}/.p/var/run ]; then
			for pid in ${MASTERMNT}/.p/var/run/*.pid; do
				# Ensure there is a pidfile to read or break
				[ "${pid}" = "${MASTERMNT}/.p/var/run/*.pid" ] && break
				pkill -15 -F ${pid} >/dev/null 2>&1 || :
				wait_pids="${wait_pids} ${pid}"
			done
			_wait ${wait_pids} || :
		fi

		jail_stop

		rm -rf \
		    ${PACKAGES}/.npkg \
		    ${POUDRIERE_DATA}/packages/${MASTERNAME}/.latest/.npkg \
		    2>/dev/null || :

	fi

	export CLEANED_UP=1
}

# return 0 if the package dir exists and has packages, 0 otherwise
package_dir_exists_and_has_packages() {
	[ ! -d ${PACKAGES}/All ] && return 1
	dirempty ${PACKAGES}/All && return 1
	# Check for non-empty directory with no packages in it
	for pkg in ${PACKAGES}/All/*.${PKG_EXT}; do
		[ "${pkg}" = \
		    "${PACKAGES}/All/*.${PKG_EXT}" ] \
		    && return 1
		# Stop on first match
		break
	done
	return 0
}

sanity_check_pkg() {
	[ $# -eq 1 ] || eargs sanity_check_pkg pkg
	local pkg="$1"
	local depfile origin pkgname

	pkg_get_origin origin "${pkg}"
	pkgname="${pkg##*/}"
	pkgname="${pkgname%.*}"
	pkg_is_needed "${pkgname}" || return 0
	deps_file depfile "${pkg}"
	while read dep; do
		if [ ! -e "${PACKAGES}/All/${dep}.${PKG_EXT}" ]; then
			msg_debug "${pkg} needs missing ${PACKAGES}/All/${dep}.${PKG_EXT}"
			msg "Deleting ${pkg##*/}: missing dependency: ${dep}"
			delete_pkg "${pkg}"
			return 65	# Package deleted, need another pass
		fi
	done < "${depfile}"

	return 0
}

sanity_check_pkgs() {
	local ret=0

	package_dir_exists_and_has_packages || return 0

	parallel_start
	for pkg in ${PACKAGES}/All/*.${PKG_EXT}; do
		parallel_run sanity_check_pkg "${pkg}" || ret=$?
	done
	parallel_stop || ret=$?
	[ ${ret} -eq 0 ] && return 0	# Nothing deleted
	[ ${ret} -eq 65 ] && return 1	# Packages deleted
	err 1 "Failure during sanity check"
}

check_leftovers() {
	[ $# -eq 1 ] || eargs check_leftovers mnt
	local mnt="${1}"

	( cd "${mnt}" && \
	    mtree -X ${mnt}/.p/mtree.preinstexclude -f ${mnt}/.p/mtree.preinst \
	    -p . ) | while read l; do
		local changed read_again

		changed=
		while :; do
			read_again=0

			# Handle leftover read from changed paths
			case ${l} in
			*extra|*missing|extra:*|*changed|*:*)
				if [ -n "${changed}" ]; then
					echo "${changed}"
					changed=
				fi
				;;
			esac
			case ${l} in
			*extra)
				if [ -d ${mnt}/${l% *} ]; then
					find ${mnt}/${l% *} -exec echo "+ {}" \;
				else
					echo "+ ${mnt}/${l% *}"
				fi
				;;
			*missing)
				l=${l#./}
				echo "- ${mnt}/${l% *}"
				;;
			*changed)
				changed="M ${mnt}/${l% *}"
				read_again=1
				;;
			extra:*)
				if [ -d ${mnt}/${l#* } ]; then
					find ${mnt}/${l#* } -exec echo "+ {}" \;
				else
					echo "+ ${mnt}/${l#* }"
				fi
				;;
			*:*)
				changed="M ${mnt}/${l%:*} ${l#*:}"
				read_again=1
				;;
			*)
				changed="${changed} ${l}"
				read_again=1
				;;
			esac
			# Need to read again to find all changes
			[ ${read_again} -eq 1 ] && read l && continue
			[ -n "${changed}" ] && echo "${changed}"
			break
		done
	done
}

check_fs_violation() {
	[ $# -eq 6 ] || eargs check_fs_violation mnt mtree_target port \
	    status_msg err_msg status_value
	local mnt="$1"
	local mtree_target="$2"
	local port="$3"
	local status_msg="$4"
	local err_msg="$5"
	local status_value="$6"
	local tmpfile=$(mktemp -t check_fs_violation)
	local ret=0

	msg_n "${status_msg}..."
	( cd "${mnt}" && mtree -X ${mnt}/.p/mtree.${mtree_target}exclude \
		-f ${mnt}/.p/mtree.${mtree_target} \
		-p . ) >> ${tmpfile}
	echo " done"

	if [ -s ${tmpfile} ]; then
		msg "Error: ${err_msg}"
		cat ${tmpfile}
		bset_job_status "${status_value}" "${port}"
		job_msg_verbose "Status   ${COLOR_PORT}${port}${COLOR_RESET}: ${status_value}"
		ret=1
	fi
	rm -f ${tmpfile}

	return $ret
}

gather_distfiles() {
	[ $# -eq 3 ] || eargs gather_distfiles origin from to
	local origin="$1"
	local from=$(realpath $2)
	local to=$(realpath $3)
	local sub dists d tosubd specials special

	port_var_fetch "${origin}" \
	    DIST_SUBDIR sub \
	    ALLFILES dists \
	    _DEPEND_SPECIALS specials || \
	    err 1 "Failed to lookup distfiles for ${origin}"

	job_msg_verbose "Status   ${COLOR_PORT}${origin}${COLOR_RESET}: distfiles ${from} -> ${to}"
	for d in ${dists}; do
		[ -f ${from}/${sub}/${d} ] || continue
		tosubd=${to}/${sub}/${d}
		mkdir -p ${tosubd%/*} || return 1
		do_clone "${from}/${sub}/${d}" "${to}/${sub}/${d}" || return 1
	done

	for special in ${specials}; do
		case "${special}" in
		${PORTSDIR}/*) special=${special#${PORTSDIR}/} ;;
		esac
		gather_distfiles ${special} ${from} ${to}
	done

	return 0
}

# Build+test port and return 1 on first failure
# Return 2 on test failure if PORTTESTING_FATAL=no
_real_build_port() {
	[ $# -ne 1 ] && eargs _real_build_port portdir
	local portdir=$1
	local port=${portdir##${PORTSDIR}/}
	local mnt
	local log
	local network
	local hangstatus
	local pkgenv phaseenv jpkg
	local targets install_order
	local jailuser
	local testfailure=0
	local max_execution_time allownetworking

	_my_path mnt
	_log_path log

	# Use bootstrap PKG when not building pkg itself.
	if false && [ ${QEMU_EMULATING} -eq 1 ]; then
		case "${port}" in
		ports-mgmt/pkg|ports-mgmt/pkg-devel) ;;
		*)
			if ensure_pkg_installed; then
				export PKG_BIN="/.p/pkg-static"
			fi
			;;
		esac
	fi

	for jpkg in ${ALLOW_MAKE_JOBS_PACKAGES}; do
		case "${PKGNAME%-*}" in
		${jpkg})
			job_msg_verbose "Allowing MAKE_JOBS for ${COLOR_PORT}${port}${COLOR_RESET}"
			sed -i '' '/DISABLE_MAKE_JOBS=poudriere/d' \
			    ${mnt}/etc/make.conf
			break
			;;
		esac
	done
	allownetworking=0
	for jpkg in ${ALLOW_NETWORKING_PACKAGES}; do
		case "${PKGNAME%-*}" in
		${jpkg})
			job_msg_warn "ALLOW_NETWORKING_PACKAGES: Allowing full network access for ${COLOR_PORT}${port}${COLOR_RESET}"
			msg_warn "ALLOW_NETWORKING_PACKAGES: Allowing full network access for ${COLOR_PORT}${port}${COLOR_RESET}"
			allownetworking=1
			JNETNAME="n"
			break
			;;
		esac
	done

	# Must install run-depends as 'actual-package-depends' and autodeps
	# only consider installed packages as dependencies
	jailuser=root
	if [ "${BUILD_AS_NON_ROOT}" = "yes" ] &&
	    [ -z "$(injail /usr/bin/make -C ${portdir} -VNEED_ROOT)" ]; then
		jailuser=${PORTBUILD_USER}
	fi
	# XXX: run-depends can come out of here with some bsd.port.mk
	# changes. Easier once pkg_install is EOL.
	install_order="run-depends stage package"
	# Don't need to install if only making packages and not
	# testing.
	[ -n "${PORTTESTING}" ] && \
	    install_order="${install_order} install-mtree install"
	targets="check-sanity pkg-depends fetch-depends fetch checksum \
		  extract-depends extract patch-depends patch build-depends \
		  lib-depends configure build ${install_order} \
		  ${PORTTESTING:+deinstall}"

	# If not testing, then avoid rechecking deps in build/install;
	# When testing, check depends twice to ensure they depend on
	# proper files, otherwise they'll hit 'package already installed'
	# errors.
	if [ -z "${PORTTESTING}" ]; then
		PORT_FLAGS="${PORT_FLAGS} NO_DEPENDS=yes"
	else
		PORT_FLAGS="${PORT_FLAGS} STRICT_DEPENDS=yes"
	fi

	for phase in ${targets}; do
		max_execution_time=${MAX_EXECUTION_TIME}
		phaseenv=
		JUSER=${jailuser}
		bset_job_status "${phase}" "${port}"
		job_msg_verbose "Status   ${COLOR_PORT}${port}${COLOR_RESET}: ${COLOR_PHASE}${phase}"
		[ -n "${PORTTESTING}" ] && \
		    phaseenv="${phaseenv} DEVELOPER_MODE=yes"
		case ${phase} in
		check-sanity)
			[ -n "${PORTTESTING}" ] && \
			    phaseenv="${phaseenv} DEVELOPER=1"
			;;
		fetch)
			mkdir -p ${mnt}/portdistfiles
			if [ "${DISTFILES_CACHE}" != "no" ]; then
				echo "DISTDIR=/portdistfiles" >> ${mnt}/etc/make.conf
				gather_distfiles "${port}" ${DISTFILES_CACHE} ${mnt}/portdistfiles || return 1
			fi
			JNETNAME="n"
			JUSER=root
			;;
		extract)
			max_execution_time=3600
			if [ "${JUSER}" != "root" ]; then
				chown -R ${JUSER} ${mnt}/wrkdirs
			fi
			;;
		configure) [ -n "${PORTTESTING}" ] && markfs prebuild ${mnt} ;;
		run-depends)
			JUSER=root
			if [ -n "${PORTTESTING}" ]; then
				check_fs_violation ${mnt} prebuild "${port}" \
				    "Checking for filesystem violations" \
				    "Filesystem touched during build:" \
				    "build_fs_violation" ||
				if [ "${PORTTESTING_FATAL}" != "no" ]; then
					return 1
				else
					testfailure=2
				fi
			fi
			;;
		checksum|*-depends|install-mtree) JUSER=root ;;
		stage) [ -n "${PORTTESTING}" ] && markfs prestage ${mnt} ;;
		install)
			max_execution_time=3600
			JUSER=root
			[ -n "${PORTTESTING}" ] && markfs preinst ${mnt}
			;;
		package)
			max_execution_time=3600
			if [ -n "${PORTTESTING}" ]; then
				check_fs_violation ${mnt} prestage "${port}" \
				    "Checking for staging violations" \
				    "Filesystem touched during stage (files must install to \${STAGEDIR}):" \
				    "stage_fs_violation" || if [ "${PORTTESTING_FATAL}" != "no" ]; then
					return 1
				else
					testfailure=2
				fi
			fi
			;;
		deinstall)
			max_execution_time=3600
			JUSER=root
			# Skip for all linux ports, they are not safe
			if [ "${PKGNAME%%*linux*}" != "" ]; then
				msg "Checking shared library dependencies"
				# Not using PKG_BIN to avoid bootstrap issues.
				injail "${LOCALBASE}/sbin/pkg" query '%Fp' "${PKGNAME}" | \
				    injail xargs readelf -d 2>/dev/null | \
				    grep NEEDED | sort -u
			fi
			;;
		esac

		print_phase_header ${phase}

		if [ "${phase}" = "package" ]; then
			echo "PACKAGES=/.npkg" >> ${mnt}/etc/make.conf
			# Create sandboxed staging dir for new package for this build
			rm -rf "${PACKAGES}/.npkg/${PKGNAME}"
			mkdir -p "${PACKAGES}/.npkg/${PKGNAME}"
			${NULLMOUNT} \
				"${PACKAGES}/.npkg/${PKGNAME}" \
				${mnt}/.npkg
			chown -R ${JUSER} ${mnt}/.npkg
			:> "${mnt}/.npkg_mounted"
		fi

		if [ "${JUSER}" = "root" ]; then
			export UID=0
			export GID=0
		else
			export UID=${PORTBUILD_UID}
			export GID=${PORTBUILD_UID}
		fi

		if [ "${phase#*-}" = "depends" ]; then
			# No need for nohang or PORT_FLAGS for *-depends
			injail /usr/bin/env USE_PACKAGE_DEPENDS_ONLY=1 ${phaseenv} \
			    /usr/bin/make -C ${portdir} ${phase} || return 1
		else
			# Only set PKGENV during 'package' to prevent
			# testport-built packages from going into the main repo
			# Also enable during stage/install since it now
			# uses a pkg for pkg_tools
			if [ "${phase}" = "package" ]; then
				pkgenv="${PKGENV}"
			else
				pkgenv=
			fi

			nohang ${max_execution_time} ${NOHANG_TIME} \
				${log}/logs/${PKGNAME}.log \
				${MASTERMNT}/.p/var/run/${MY_JOBID:-00}_nohang.pid \
				injail /usr/bin/env ${pkgenv} ${phaseenv} ${PORT_FLAGS} \
				/usr/bin/make -C ${portdir} ${phase}
			hangstatus=$? # This is done as it may return 1 or 2 or 3
			if [ $hangstatus -ne 0 ]; then
				# 1 = cmd failed, not a timeout
				# 2 = log timed out
				# 3 = cmd timeout
				if [ $hangstatus -eq 2 ]; then
					msg "Killing runaway build after ${NOHANG_TIME} seconds with no output"
					bset_job_status "${phase}/runaway" "${port}"
					job_msg_verbose "Status   ${COLOR_PORT}${port}${COLOR_RESET}: ${COLOR_PHASE}runaway"
				elif [ $hangstatus -eq 3 ]; then
					msg "Killing timed out build after ${max_execution_time} seconds"
					bset_job_status "${phase}/timeout" "${port}"
					job_msg_verbose "Status   ${COLOR_PORT}${port}${COLOR_RESET}: ${COLOR_PHASE}timeout"
				fi
				return 1
			fi
		fi

		if [ "${phase}" = "checksum" ] && \
		    [ ${allownetworking} -eq 0 ]; then
			JNETNAME=""
		fi
		print_phase_footer

		if [ "${phase}" = "checksum" -a "${DISTFILES_CACHE}" != "no" ]; then
			gather_distfiles "${port}" ${mnt}/portdistfiles ${DISTFILES_CACHE} || return 1
		fi

		if [ "${phase}" = "stage" -a -n "${PORTTESTING}" ]; then
			local die=0

			bset_job_status "stage-qa" "${port}"
			if ! injail /usr/bin/env DEVELOPER=1 ${PORT_FLAGS} \
			    /usr/bin/make -C ${portdir} stage-qa; then
				msg "Error: stage-qa failures detected"
				[ "${PORTTESTING_FATAL}" != "no" ] &&
					return 1
				die=1
			fi

			bset_job_status "check-plist" "${port}"
			if ! injail /usr/bin/env DEVELOPER=1 ${PORT_FLAGS} \
			    /usr/bin/make -C ${portdir} check-plist; then
				msg "Error: check-plist failures detected"
				[ "${PORTTESTING_FATAL}" != "no" ] &&
					return 1
				die=1
			fi

			if [ ${die} -eq 1 ]; then
				testfailure=2
				die=0
			fi
		fi

		if [ "${phase}" = "deinstall" ]; then
			local add=$(mktemp -t lo.add)
			local add1=$(mktemp -t lo.add1)
			local del=$(mktemp -t lo.del)
			local del1=$(mktemp -t lo.del1)
			local mod=$(mktemp -t lo.mod)
			local mod1=$(mktemp -t lo.mod1)
			local die=0
			PREFIX=$(injail /usr/bin/env ${PORT_FLAGS} /usr/bin/make -C ${portdir} -VPREFIX)

			msg "Checking for extra files and directories"
			bset_job_status "leftovers" "${port}"

			if [ -f "${mnt}${PORTSDIR}/Mk/Scripts/check_leftovers.sh" ]; then
				check_leftovers ${mnt} | sed -e "s|${mnt}||" |
				    injail /usr/bin/env PORTSDIR=${PORTSDIR} \
				    ${PORT_FLAGS} /bin/sh \
				    ${PORTSDIR}/Mk/Scripts/check_leftovers.sh \
				    ${port} | while read modtype data; do
					case "${modtype}" in
						+) echo "${data}" >> ${add} ;;
						-) echo "${data}" >> ${del} ;;
						M) echo "${data}" >> ${mod} ;;
					esac
				done
			else
				# LEGACY - Support for older ports tree.
				local users user homedirs plistsub_sed
				plistsub_sed=$(injail /usr/bin/env ${PORT_FLAGS} /usr/bin/make -C ${portdir} -V'PLIST_SUB:C/"//g:NLIB32*:NPERL_*:NPREFIX*:N*="":N*="@comment*:C/(.*)=(.*)/-es!\2!%%\1%%!g/')

				users=$(injail /usr/bin/make -C ${portdir} -VUSERS)
				homedirs=""
				for user in ${users}; do
					user=$(grep ^${user}: ${mnt}${PORTSDIR}/UIDs | cut -f 9 -d : | sed -e "s|/usr/local|${PREFIX}| ; s|^|${mnt}|")
					homedirs="${homedirs} ${user}"
				done

				check_leftovers ${mnt} | \
					while read modtype path extra; do
					local ppath ignore_path=0

					# If this is a directory, use @dirrm in output
					if [ -d "${path}" ]; then
						ppath="@dirrm "`echo $path | sed \
							-e "s,^${mnt},," \
							-e "s,^${PREFIX}/,," \
							${plistsub_sed} \
						`
					else
						ppath=`echo "$path" | sed \
							-e "s,^${mnt},," \
							-e "s,^${PREFIX}/,," \
							${plistsub_sed} \
						`
					fi
					case $modtype in
					+)
						if [ -d "${path}" ]; then
							# home directory of users created
							case " ${homedirs} " in
							*\ ${path}\ *) continue;;
							*\ ${path}/*\ *) continue;;
							esac
						fi
						case "${ppath}" in
						# gconftool-2 --makefile-uninstall-rule is unpredictable
						etc/gconf/gconf.xml.defaults/%gconf-tree*.xml) ;;
						# fc-cache - skip for now
						/var/db/fontconfig/*) ;;
						*) echo "${ppath}" >> ${add} ;;
						esac
						;;
					-)
						# Skip if it is PREFIX and non-LOCALBASE. See misc/kdehier4
						# or mail/qmail for examples
						[ "${path#${mnt}}" = "${PREFIX}" -a \
							"${LOCALBASE}" != "${PREFIX}" ] && ignore_path=1

						# fc-cache - skip for now
						case "${ppath}" in
						/var/db/fontconfig/*) ignore_path=1 ;;
						esac

						if [ $ignore_path -eq 0 ]; then
							echo "${ppath}" >> ${del}
						fi
						;;
					M)
						case "${ppath}" in
						# gconftool-2 --makefile-uninstall-rule is unpredictable
						etc/gconf/gconf.xml.defaults/%gconf-tree*.xml) ;;
						# This is a cache file for gio modules could be modified for any gio modules
						lib/gio/modules/giomodule.cache) ;;
						# removal of info files leaves entry uneasy to cleanup in info/dir
						# accept a modification of this file
						info/dir) ;;
						*/info/dir) ;;
						# The is pear database cache
						%%PEARDIR%%/.depdb|%%PEARDIR%%/.filemap) ;;
						#ls-R files from texmf are often regenerated
						*/ls-R);;
						# Octave packages database, blank lines can be inserted between pre-install and post-deinstall
						share/octave/octave_packages) ;;
						# xmlcatmgr is constantly updating catalog.ports ignore modification to that file
						share/xml/catalog.ports);;
						# fc-cache - skip for now
						/var/db/fontconfig/*) ;;
						*) echo "${ppath#@dirrm } ${extra}" >> ${mod} ;;
						esac
						;;
					esac
				done
			fi

			sort ${add} > ${add1}
			sort ${del} > ${del1}
			sort ${mod} > ${mod1}
			comm -12 ${add1} ${del1} >> ${mod1}
			comm -23 ${add1} ${del1} > ${add}
			comm -13 ${add1} ${del1} > ${del}
			if [ -s "${add}" ]; then
				msg "Error: Files or directories left over:"
				die=1
				grep -v "^@dirrm" ${add}
				grep "^@dirrm" ${add} | sort -r
			fi
			if [ -s "${del}" ]; then
				msg "Error: Files or directories removed:"
				die=1
				cat ${del}
			fi
			if [ -s "${mod}" ]; then
				msg "Error: Files or directories modified:"
				die=1
				cat ${mod1}
			fi
			[ ${die} -eq 1 -a "${SCRIPTPATH##*/}" = "testport.sh" \
			    -a "${PREFIX}" != "${LOCALBASE}" ] && msg \
			    "This test was done with PREFIX!=LOCALBASE which \
may show failures if the port does not respect PREFIX. \
Try testport with -n to use PREFIX=LOCALBASE"
			rm -f ${add} ${add1} ${del} ${del1} ${mod} ${mod1}
			[ $die -eq 0 ] || if [ "${PORTTESTING_FATAL}" != "no" ]; then
				return 1
			else
				testfailure=2
			fi
		fi
	done

	if [ -d "${PACKAGES}/.npkg/${PKGNAME}" ]; then
		# everything was fine we can copy the package to the package
		# directory
		find ${PACKAGES}/.npkg/${PKGNAME} \
			-mindepth 1 \( -type f -or -type l \) | while read pkg_path; do
			pkg_file=${pkg_path#${PACKAGES}/.npkg/${PKGNAME}}
			pkg_base=${pkg_file%/*}
			mkdir -p ${PACKAGES}/${pkg_base}
			mv ${pkg_path} ${PACKAGES}/${pkg_base}
		done
	fi

	bset_job_status "build_port_done" "${port}"
	return ${testfailure}
}

# Wrapper to ensure JUSER is reset and any other cleanup needed
build_port() {
	local ret
	_real_build_port "$@" || ret=$?
	JUSER=root
	return ${ret}
}

# Save wrkdir and return path to file
save_wrkdir() {
	[ $# -ne 4 ] && eargs save_wrkdir mnt port portdir phase
	local mnt=$1
	local port="$2"
	local portdir="$3"
	local phase="$4"
	local tardir=${POUDRIERE_DATA}/wrkdirs/${MASTERNAME}/${PTNAME}
	local tarname=${tardir}/${PKGNAME}.${WRKDIR_ARCHIVE_FORMAT}
	local mnted_portdir=${mnt}/wrkdirs/${portdir}

	[ "${SAVE_WRKDIR}" != "no" ] || return 0
	# Only save if not in fetch/checksum phase
	[ "${failed_phase}" != "fetch" -a "${failed_phase}" != "checksum" -a \
		"${failed_phase}" != "extract" ] || return 0

	mkdir -p ${tardir}

	# Tar up the WRKDIR, and ignore errors
	case ${WRKDIR_ARCHIVE_FORMAT} in
	tar) COMPRESSKEY="" ;;
	tgz) COMPRESSKEY="z" ;;
	tbz) COMPRESSKEY="j" ;;
	txz) COMPRESSKEY="J" ;;
	esac
	rm -f ${tarname}
	tar -s ",${mnted_portdir},," -c${COMPRESSKEY}f ${tarname} ${mnted_portdir}/work > /dev/null 2>&1

	job_msg "Saved ${COLOR_PORT}${port}${COLOR_RESET} wrkdir to: ${tarname}"
}

start_builder() {
	local id=$1
	local arch=$2
	local mnt MY_JOBID

	MY_JOBID=${id}
	_my_path mnt

	# Jail might be lingering from previous build. Already recursively
	# destroyed all the builder datasets, so just try stopping the jail
	# and ignore any errors
	stop_builder "${id}"
	mkdir -p "${mnt}"
	clonefs ${MASTERMNT} ${mnt} prepkg
	markfs prepkg ${mnt} >/dev/null
	do_jail_mounts "${MASTERMNT}" ${mnt} ${arch} ${jname}
	do_portbuild_mounts ${mnt} ${jname} ${ptname} ${setname}
	jstart
	bset ${id} status "idle:"
	run_hook builder start "${id}" "${mnt}"
}

start_builders() {
	local arch=$(injail uname -p)

	bset builders "${JOBS}"
	bset status "starting_builders:"
	parallel_start
	for j in ${JOBS}; do
		parallel_run start_builder ${j} ${arch}
	done
	parallel_stop
}

stop_builder() {
	[ $# -eq 1 ] || eargs stop_builder jobid
	local jobid="$1"
	local mnt MY_JOBID

	MY_JOBID="${jobid}"
	_my_path mnt
	run_hook builder stop "${jobid}" "${mnt}"
	jstop
	destroyfs "${mnt}" jail
}

stop_builders() {
	local PARALLEL_JOBS real_parallel_jobs

	# wait for the last running processes
	cat ${MASTERMNT}/.p/var/run/*.pid 2>/dev/null | xargs pwait 2>/dev/null

	if [ ${PARALLEL_JOBS} -ne 0 ]; then
		msg "Stopping ${PARALLEL_JOBS} builders"

		real_parallel_jobs=${PARALLEL_JOBS}
		if [ ${UMOUNT_BATCHING} -eq 0 ]; then
			# Limit builders
			PARALLEL_JOBS=2
		fi
		parallel_start
		for j in ${JOBS-$(jot -w %02d ${real_parallel_jobs})}; do
			parallel_run stop_builder "${j}"
		done
		parallel_stop
	fi

	# No builders running, unset JOBS
	JOBS=""
}

sanity_check_queue() {
	local always_fail=${1:-1}
	local crashed_packages dependency_cycles deps pkgname origin
	local failed_phase pwd

	pwd="${PWD}"
	cd "${MASTERMNT}/.p"

	# If there are still packages marked as "building" they have crashed
	# and it's likely some poudriere or system bug
	crashed_packages=$( \
		find building -type d -mindepth 1 -maxdepth 1 | \
		sed -e "s,^building/,," | tr '\n' ' ' \
	)
	[ -z "${crashed_packages}" ] ||	\
		err 1 "Crashed package builds detected: ${crashed_packages}"

	# Check if there's a cycle in the need-to-build queue
	dependency_cycles=$(\
		find deps -mindepth 2 | \
		sed -e "s,^deps/,," -e 's:/: :' | \
		# Only cycle errors are wanted
		tsort 2>&1 >/dev/null | \
		sed -e 's/tsort: //' | \
		awk -f ${AWKPREFIX}/dependency_loop.awk \
	)

	if [ -n "${dependency_cycles}" ]; then
		err 1 "Dependency loop detected:
${dependency_cycles}"
	fi

	if [ ${always_fail} -eq 0 ]; then
		cd "${pwd}"
		return 0
	fi

	dead_packages=
	highest_dep=
	while read deps pkgname; do
		[ -z "${highest_dep}" ] && highest_dep=${deps}
		[ ${deps} -ne ${highest_dep} ] && break
		dead_packages="${dead_packages} ${pkgname}"
	done <<-EOF
	$(find deps -mindepth 2 | \
	    sed -e "s,^deps/,," -e 's:/: :' | \
	    tsort -D 2>/dev/null | sort -nr)
	EOF

	if [ -n "${dead_packages}" ]; then
		failed_phase="stuck_in_queue"
		for pkgname in ${dead_packages}; do
			crashed_build "${pkgname}" "${failed_phase}"
		done
		cd "${pwd}"
		return 0
	fi

	# No cycle, there's some unknown poudriere bug
	err 1 "Unknown stuck queue bug detected. Please submit the entire build output to poudriere developers.
$(find ${MASTERMNT}/.p/building ${MASTERMNT}/.p/pool ${MASTERMNT}/.p/deps ${MASTERMNT}/.p/cleaning)"
}

queue_empty() {
	[ "${PWD}" = "${MASTERMNT}/.p/pool" ] || \
	    err 1 "queue_empty requires PWD=${MASTERMNT}/.p/pool"
	local pool_dir dirs
	local n

	# CWD is MASTERMNT/.p/pool

	dirs="../deps ${POOL_BUCKET_DIRS}"

	n=0
	# Check twice that the queue is empty. This avoids racing with
	# clean.sh and balance_pool() moving files between the dirs.
	while [ ${n} -lt 2 ]; do
		for pool_dir in ${dirs}; do
			if ! dirempty ${pool_dir}; then
				return 1
			fi
		done
		n=$((n + 1))
	done

	# Queue is empty
	return 0
}

job_done() {
	[ "${PWD}" = "${MASTERMNT}/.p/pool" ] || \
	    err 1 "job_done requires PWD=${MASTERMNT}/.p/pool"
	[ $# -eq 1 ] || eargs job_done j
	local j="$1"
	local pkgname status

	# CWD is MASTERMNT/.p/pool

	# Failure to find this indicates the job is already done.
	hash_get builder_pkgnames "${j}" pkgname || return 1
	hash_unset builder_pids "${j}"
	hash_unset builder_pkgnames "${j}"
	rm -f "../var/run/${j}.pid"
	_bget status ${j} status
	rmdir "../building/${pkgname}"
	if [ "${status%%:*}" = "done" ]; then
		bset ${j} status "idle:"
	else
		# Try to cleanup and mark build crashed
		MY_JOBID="${j}" crashed_build "${pkgname}" "${status%%:*}"
		bset ${j} status "crashed:"
	fi
}

build_queue() {
	[ "${PWD}" = "${MASTERMNT}/.p/pool" ] || \
	    err 1 "build_queue requires PWD=${MASTERMNT}/.p/pool"
	local j jobid pid pkgname builders_active queue_empty
	local builders_idle idle_only timeout

	mkfifo ${MASTERMNT}/.p/builders.pipe
	exec 6<> ${MASTERMNT}/.p/builders.pipe
	rm -f ${MASTERMNT}/.p/builders.pipe
	queue_empty=0

	msg "Hit CTRL+t at any time to see build progress and stats"

	idle_only=0
	while :; do
		builders_active=0
		builders_idle=0
		timeout=30
		for j in ${JOBS}; do
			# Check if pid is alive. A job will have no PID if it
			# is idle. idle_only=1 is a quick check for giving
			# new work only to idle workers.
			if hash_get builder_pids "${j}" pid; then
				if [ ${idle_only} -eq 1 ] ||
				    kill -0 ${pid} 2>/dev/null; then
					# Job still active or skipping busy.
					builders_active=1
					continue
				fi
				job_done "${j}"
				# Set a 0 timeout to quickly rescan for idle
				# builders to toss a job at.
				[ ${queue_empty} -eq 0 -a \
				    ${builders_idle} -eq 1 ] && timeout=0
			fi

			# This builder is idle and needs work.

			[ ${queue_empty} -eq 0 ] || continue

			next_in_queue pkgname || \
			    err 1 "Failed to find a package from the queue."

			if [ -z "${pkgname}" ]; then
				# Check if the ready-to-build pool and need-to-build pools
				# are empty
				queue_empty && queue_empty=1

				# Pool is waiting on dep, wait until a build
				# is done before checking the queue again
				builders_idle=1
			else
				MY_JOBID="${j}" \
				    PORTTESTING=$(get_porttesting "${pkgname}") \
				    spawn_protected build_pkg "${pkgname}"
				pid=$!
				echo "${pid}" > "../var/run/${j}.pid"
				hash_set builder_pids "${j}" "${pid}"
				hash_set builder_pkgnames "${j}" "${pkgname}"

				# A new job is spawned, try to read the queue
				# just to keep things moving
				builders_active=1
			fi
		done

		if [ ${queue_empty} -eq 1 ]; then
			if [ ${builders_active} -eq 1 ]; then
				# The queue is empty, but builds are still
				# going. Wait on them below.

				# FALLTHROUGH
			else
				# All work is done
				sanity_check_queue 0
				break
			fi
		fi

		# If builders are idle then there is a problem.
		[ ${builders_active} -eq 1 ] || sanity_check_queue

		# Wait for an event from a child. All builders are busy.
		unset jobid; until trappedinfo=; read -t ${timeout} jobid <&6 ||
			[ -z "$trappedinfo" ]; do :; done
		if [ -n "${jobid}" ]; then
			# A job just finished.
			if job_done "${jobid}"; then
				# Do a quick scan to try dispatching
				# ready-to-build to idle builders.
				idle_only=1
			else
				# The job is already done. It was found to be
				# done by a kill -0 check in a scan.
			fi
		else
			# No event found. The next scan will check for
			# crashed builders and deadlocks by validating
			# every builder is really non-idle.
			idle_only=0
		fi
	done
	exec 6<&- 6>&-
}

calculate_tobuild() {
	local nbq nbb nbf nbi nbsndone nremaining

	_bget nbq stats_queued 2>/dev/null || nbq=0
	_bget nbb stats_built 2>/dev/null || nbb=0
	_bget nbf stats_failed 2>/dev/null || nbf=0
	_bget nbi stats_ignored 2>/dev/null || nbi=0
	_bget nbs stats_skipped 2>/dev/null || nbs=0

	ndone=$((nbb + nbf + nbi + nbs))
	nremaining=$((nbq - ndone))

	echo ${nremaining}
}

status_is_stopped() {
	[ $# -eq 1 ] || eargs status_is_stopped status
	local status="$1"
	case "${status}" in
		sigterm:|sigint:|crashed:|stop:|stopped:*) return 0 ;;
	esac
	return 1
}

calculate_elapsed_from_log() {
	[ $# -eq 2 ] || eargs calculate_elapsed_from_log now log
	local now="$1"
	local log="$2"

	[ -f "${log}/.poudriere.status" ] || return 1
	start_end_time=$(stat -f '%B %m' ${log}/.poudriere.status.journal% 2>/dev/null || stat -f '%B %m' ${log}/.poudriere.status)
	start_time=${start_end_time% *}
	if status_is_stopped "${status}"; then
		end_time=${start_end_time#* }
	else
		end_time=${now}
	fi
	_start_time=${start_time}
	_end_time=${end_time}
	_elapsed_time=$((${end_time} - ${start_time}))
	return 0
}

calculate_duration() {
	[ $# -eq 2 ] || eargs calculate_duration var_return elapsed
	local var_return="$1"
	local _elapsed="$2"
	local seconds minutes hours _duration

	seconds=$((${_elapsed} % 60))
	minutes=$(((${_elapsed} / 60) % 60))
	hours=$((${_elapsed} / 3600))

	_duration=$(printf "%02d:%02d:%02d" ${hours} ${minutes} ${seconds})

	setvar "${var_return}" "${_duration}"
}

# Build ports in parallel
# Returns when all are built.
parallel_build() {
	local jname=$1
	local ptname=$2
	local setname=$3
	local real_parallel_jobs=${PARALLEL_JOBS}
	local nremaining=$(calculate_tobuild)

	# Subtract the 1 for the main port to test
	[ "${SCRIPTPATH##*/}" = "testport.sh" ] && \
	    nremaining=$((${nremaining} - 1))

	# If pool is empty, just return
	[ ${nremaining} -eq 0 ] && return 0

	# Minimize PARALLEL_JOBS to queue size
	[ ${PARALLEL_JOBS} -gt ${nremaining} ] && PARALLEL_JOBS=${nremaining##* }

	msg "Building ${nremaining} packages using ${PARALLEL_JOBS} builders"
	JOBS="$(jot -w %02d ${PARALLEL_JOBS})"

	bset status "starting_jobs:"
	msg "Starting/Cloning builders"
	start_builders

	coprocess_start pkg_cacher

	bset status "parallel_build:"

	[ ! -d "${MASTERMNT}/.p/pool" ] && err 1 "Build pool is missing"
	cd "${MASTERMNT}/.p/pool"

	build_queue

	cd ..

	bset status "stopping_jobs:"
	stop_builders

	bset status "updating_stats:"
	update_stats || msg_warn "Error updating build stats"
	update_stats_done=1

	bset status "idle:"

	# Restore PARALLEL_JOBS
	PARALLEL_JOBS=${real_parallel_jobs}

	return 0
}

crashed_build() {
	[ $# -eq 2 ] || eargs crashed_build pkgname failed_phase
	local pkgname="$1"
	local failed_phase="$2"
	local origin log

	_log_path log
	cache_get_origin origin "${pkgname}"

	echo "Build crashed: ${failed_phase}" >> "${log}/logs/${pkgname}.log"

	# If the file already exists then all of this handling was done in
	# build_pkg() already; The port failed already. What crashed
	# came after.
	if ! [ -e "${log}/logs/errors/${pkgname}.log" ]; then
		# Symlink the buildlog into errors/
		ln -s "../${pkgname}.log" "${log}/logs/errors/${pkgname}.log"
		badd ports.failed \
		    "${origin} ${pkgname} ${failed_phase} ${failed_phase}"
		COLOR_ARROW="${COLOR_FAIL}" msg \
		    "${COLOR_FAIL}Finished ${COLOR_PORT}${origin}${COLOR_FAIL}: Failed: ${COLOR_PHASE}${failed_phase}"
		run_hook pkgbuild failed "${origin}" "${pkgname}" \
		    "${failed_phase}" \
		    "${log}/logs/errors/${pkgname}.log"
	fi
	clean_pool "${pkgname}" "${origin}" "${failed_phase}"
	stop_build "${pkgname}" "${origin}" 1 >> "${log}/logs/${pkgname}.log"
}

clean_pool() {
	[ $# -ne 3 ] && eargs clean_pool pkgname origin clean_rdepends
	local pkgname=$1
	local port=$2
	local clean_rdepends="$3"
	local skipped_origin

	[ -n "${MY_JOBID}" ] && bset ${MY_JOBID} status "clean_pool:"

	[ -z "${port}" -a -n "${clean_rdepends}" ] && \
	    cache_get_origin port "${pkgname}"

	# Cleaning queue (pool is cleaned here)
	sh ${SCRIPTPREFIX}/clean.sh "${MASTERMNT}" "${pkgname}" "${clean_rdepends}" | sort -u | while read skipped_pkgname; do
		cache_get_origin skipped_origin "${skipped_pkgname}"
		badd ports.skipped "${skipped_origin} ${skipped_pkgname} ${pkgname}"
		COLOR_ARROW="${COLOR_SKIP}" \
		    job_msg "${COLOR_SKIP}Skipping ${COLOR_PORT}${skipped_origin}${COLOR_SKIP}: Dependent port ${COLOR_PORT}${port}${COLOR_SKIP} ${clean_rdepends}"
		run_hook pkgbuild skipped "${skipped_origin}" "${skipped_pkgname}" "${port}"
	done

	(
		cd "${MASTERMNT}/.p"
		balance_pool || :
	)
}

print_phase_header() {
	printf "=======================<phase: %-15s>============================\n" "$1"
}

print_phase_footer() {
	echo "==========================================================================="
}

build_pkg() {
	# If this first check fails, the pool will not be cleaned up,
	# since PKGNAME is not yet set.
	[ $# -ne 1 ] && eargs build_pkg pkgname
	local pkgname="$1"
	local port portdir
	local build_failed=0
	local name
	local mnt
	local failed_status failed_phase cnt
	local clean_rdepends
	local log
	local ignore
	local errortype
	local ret=0

	_my_path mnt
	_my_name name
	_log_path log
	clean_rdepends=
	trap '' SIGTSTP
	export PKGNAME="${pkgname}" # set ASAP so jail_cleanup() can use it
	cache_get_origin port "${pkgname}"
	portdir="${PORTSDIR}/${port}"

	if [ -n "${MAX_MEMORY_BYTES}" -o -n "${MAX_FILES}" ]; then
		JEXEC_LIMITS=1
	fi

	setproctitle "build_pkg (${pkgname})" || :

	TIME_START_JOB=$(clock -monotonic)
	# Don't show timestamps in msg() which goes to logs, only job_msg()
	# which goes to master
	NO_ELAPSED_IN_MSG=1
	colorize_job_id COLOR_JOBID "${MY_JOBID}"

	job_msg "Building ${COLOR_PORT}${port}${COLOR_RESET}"
	bset_job_status "starting" "${port}"

	if [ "${USE_JEXECD}" = "no" ]; then
		# Kill everything in jail first
		jkill
	fi

	if [ ${TMPFS_LOCALBASE} -eq 1 -o ${TMPFS_ALL} -eq 1 ]; then
		if [ -f "${mnt}/${LOCALBASE:-/usr/local}/.mounted" ]; then
			umount ${UMOUNT_NONBUSY} ${mnt}/${LOCALBASE:-/usr/local}
		fi
		mnt_tmpfs localbase ${mnt}/${LOCALBASE:-/usr/local}
		do_clone -r "${MASTERMNT}/${LOCALBASE:-/usr/local}" \
		    "${mnt}/${LOCALBASE:-/usr/local}"
		:> "${mnt}/${LOCALBASE:-/usr/local}/.mounted"
	fi

	[ -f ${mnt}/.need_rollback ] && rollbackfs prepkg ${mnt}
	[ -f ${mnt}/.need_rollback ] && \
	    err 1 "Failed to rollback ${mnt} to prepkg"
	:> ${mnt}/.need_rollback

	case " ${BLACKLIST} " in
	*\ ${port}\ *) ignore="Blacklisted" ;;
	esac
	# If this port is IGNORED, skip it
	# This is checked here instead of when building the queue
	# as the list may start big but become very small, so here
	# is a less-common check
	: ${ignore:=$(injail /usr/bin/make -C ${portdir} -VIGNORE)}

	rm -rf ${mnt}/wrkdirs/* || :

	log_start 0
	msg "Building ${port}"
	buildlog_start ${portdir}

	# Ensure /dev/null exists (kern/139014)
	[ ${JAILED} -eq 0 ] && ! [ -c "${mnt}/dev/null" ] && \
	    devfs -m ${mnt}/dev rule apply path null unhide

	if [ -n "${ignore}" ]; then
		msg "Ignoring ${port}: ${ignore}"
		badd ports.ignored "${port} ${PKGNAME} ${ignore}"
		COLOR_ARROW="${COLOR_IGNORE}" job_msg "${COLOR_IGNORE}Finished ${COLOR_PORT}${port}${COLOR_IGNORE}: Ignored: ${ignore}"
		clean_rdepends="ignored"
		run_hook pkgbuild ignored "${port}" "${PKGNAME}" "${ignore}"
	else
		build_port ${portdir} || ret=$?
		if [ ${ret} -ne 0 ]; then
			build_failed=1
			# ret=2 is a test failure
			if [ ${ret} -eq 2 ]; then
				failed_phase=$(awk -f ${AWKPREFIX}/processonelog2.awk \
					${log}/logs/${PKGNAME}.log \
					2> /dev/null)
			else
				_bget failed_status ${MY_JOBID} status
				failed_phase=${failed_status%%:*}
			fi

			save_wrkdir ${mnt} "${port}" "${portdir}" "${failed_phase}" || :
		elif [ -f ${mnt}/${portdir}/.keep ]; then
			save_wrkdir ${mnt} "${port}" "${portdir}" "noneed" ||:
		fi

		if [ ${build_failed} -eq 0 ]; then
			badd ports.built "${port} ${PKGNAME}"
			COLOR_ARROW="${COLOR_SUCCESS}" job_msg "${COLOR_SUCCESS}Finished ${COLOR_PORT}${port}${COLOR_SUCCESS}: Success"
			run_hook pkgbuild success "${port}" "${PKGNAME}"
			# Cache information for next run
			pkg_cacher_queue "${port}" "${pkgname}" || :
		else
			# Symlink the buildlog into errors/
			ln -s ../${PKGNAME}.log ${log}/logs/errors/${PKGNAME}.log
			errortype=$(/bin/sh ${SCRIPTPREFIX}/processonelog.sh \
				${log}/logs/errors/${PKGNAME}.log \
				2> /dev/null)
			badd ports.failed "${port} ${PKGNAME} ${failed_phase} ${errortype}"
			COLOR_ARROW="${COLOR_FAIL}" job_msg "${COLOR_FAIL}Finished ${COLOR_PORT}${port}${COLOR_FAIL}: Failed: ${COLOR_PHASE}${failed_phase}"
			run_hook pkgbuild failed "${port}" "${PKGNAME}" "${failed_phase}" \
				"${log}/logs/errors/${PKGNAME}.log"
			# ret=2 is a test failure
			if [ ${ret} -eq 2 ]; then
				clean_rdepends=
			else
				clean_rdepends="failed"
			fi
		fi

		msg "Cleaning up wrkdir"
		injail /usr/bin/make -C "${portdir}" -DNOCLEANDEPENDS clean || :
		rm -rf ${mnt}/wrkdirs/* || :
	fi

	clean_pool ${PKGNAME} ${port} "${clean_rdepends}"

	stop_build "${PKGNAME}" ${port} ${build_failed}

	log_stop

	bset ${MY_JOBID} status "done:"

	echo ${MY_JOBID} >&6
}

stop_build() {
	[ $# -eq 3 ] || eargs stop_build pkgname origin build_failed
	local pkgname="$1"
	local origin="$2"
	local build_failed="$3"
	local mnt

	if [ -n "${MY_JOBID}" ]; then
		_my_path mnt

		if [ -f "${mnt}/.npkg_mounted" ]; then
			umount ${UMOUNT_NONBUSY} "${mnt}/.npkg"
			rm -f "${mnt}/.npkg_mounted"
		fi
		rm -rf "${PACKAGES}/.npkg/${PKGNAME}"

		if jail_has_processes; then
			msg_warn "Leftover processes:"
			injail ps auxwwd | egrep -v '(ps auxwwd|jexecd)'
		fi
		if JNETNAME="n" jail_has_processes; then
			msg_warn "Leftover processes (network jail):"
			JNETNAME="n" injail ps auxwwd | egrep -v '(ps auxwwd|jexecd)'
		fi

		if [ "${USE_JEXECD}" = "no" ]; then
			# Always kill to avoid missing anything
			jkill
		fi
	fi

	buildlog_stop "${pkgname}" ${origin} ${build_failed}
}

prefix_stderr_quick() {
	local -; set +x
	local extra="$1"
	shift 1

	{
		{ "$@"; } 2>&1 1>&3 | {
			setproctitle "${PROC_TITLE} (prefix_stderr_quick)"
			while read -r line; do
				msg_warn "${extra}: ${line}"
			done
		}
	} 3>&1
}

prefix_stderr() {
	local extra="$1"
	shift 1
	local prefixpipe prefixpid ret

	prefixpipe=$(mktemp -ut prefix_stderr.pipe)
	mkfifo "${prefixpipe}"
	(
		set +x
		setproctitle "${PROC_TITLE} (prefix_stderr)"
		while read -r line; do
			msg_warn "${extra}: ${line}"
		done
	) < ${prefixpipe} &
	prefixpid=$!
	exec 4>&2
	exec 2> "${prefixpipe}"
	rm -f "${prefixpipe}"

	ret=0
	"$@" || ret=$?

	exec 2>&4 4>&-
	wait ${prefixpid}

	return ${ret}
}

prefix_stdout() {
	local extra="$1"
	shift 1
	local prefixpipe prefixpid ret

	prefixpipe=$(mktemp -ut prefix_stdout.pipe)
	mkfifo "${prefixpipe}"
	(
		set +x
		setproctitle "${PROC_TITLE} (prefix_stdout)"
		while read -r line; do
			msg "${extra}: ${line}"
		done
	) < ${prefixpipe} &
	prefixpid=$!
	exec 3>&1
	exec > "${prefixpipe}"
	rm -f "${prefixpipe}"

	ret=0
	"$@" || ret=$?

	exec 1>&3 3>&-
	wait ${prefixpid}

	return ${ret}
}

prefix_output() {
	local extra="$1"
	shift 1

	prefix_stderr "${extra}" prefix_stdout "${extra}" "$@"
}

deps_fetch_vars() {
	[ $# -ne 3 ] && eargs deps_fetch_vars origin deps_var pkgname_var
	local origin="$1"
	local deps_var="$2"
	local pkgname_var="$3"
	local _pkgname _pkg_deps _lib_depends= _run_depends= _selected_options=
	local _changed_options= _changed_deps=
	local _existing_pkgname _existing_origin

	if [ "${CHECK_CHANGED_OPTIONS}" != "no" ]; then
		_changed_options="SELECTED_OPTIONS:O _selected_options"
	fi
	if [ "${CHECK_CHANGED_DEPS}" != "no" ]; then
		_changed_deps="LIB_DEPENDS _lib_depends RUN_DEPENDS _run_depends"
	fi
	if ! port_var_fetch "${origin}" \
	    PKGNAME _pkgname \
	    ${_changed_deps} \
	    ${_changed_options} \
	    _PDEPS='${PKG_DEPENDS} ${EXTRACT_DEPENDS} ${PATCH_DEPENDS} ${FETCH_DEPENDS} ${BUILD_DEPENDS} ${LIB_DEPENDS} ${RUN_DEPENDS}' '' \
	    '${_PDEPS:C,([^:]*):([^:]*):?.*,\2,:C,^${PORTSDIR}/,,:O:u}' \
	    _pkg_deps; then
		msg_error "Error fetching dependencies for ${COLOR_PORT}${origin}${COLOR_RESET}"
		return 1
	fi

	[ -n "${_pkgname}" ] || \
	    err 1 "deps_fetch_vars: failed to get PKGNAME for ${origin}"

	setvar "${deps_var}" "${_pkg_deps}"
	setvar "${pkgname_var}" "${_pkgname}"

	if ! shash_get origin-pkgname "${origin}" _existing_pkgname; then
		# Make sure this origin did not already exist
		cache_get_origin _existing_origin "${_pkgname}" 2>/dev/null || :
		# It may already exist due to race conditions, it is not
		# harmful. Just ignore.
		if [ "${_existing_origin}" != "${origin}" ]; then
			[ -n "${_existing_origin}" ] && \
			    err 1 "Duplicated origin for ${_pkgname}: ${COLOR_PORT}${origin}${COLOR_RESET} AND ${COLOR_PORT}${_existing_origin}${COLOR_RESET}. Rerun with -v to see which ports are depending on these."
			shash_set origin-pkgname "${origin}" "${_pkgname}"
			shash_set pkgname-origin "${_pkgname}" "${origin}"
		fi
	else
		# compute_deps raced and managed to process the same port
		# before creating its pool dir.  This is wasted time
		# but is harmless.  We could add some kind of locking
		# based on the origin name, but it's probably not
		# worth it.  The same race exists in the above case.
		return 0
	fi

	shash_set pkgname-deps "${_pkgname}" "${_pkg_deps}"
	# Store for delete_old_pkg
	if [ -n "${_lib_depends}" ]; then
		shash_set pkgname-lib_deps "${_pkgname}" "${_lib_depends}"
	fi
	if [ -n "${_run_depends}" ]; then
		shash_set pkgname-run_deps "${_pkgname}" "${_run_depends}"
	fi
	if [ -n "${_selected_options}" ]; then
		shash_set pkgname-options "${_pkgname}" "${_selected_options}"
	fi
}

deps_file() {
	[ $# -ne 2 ] && eargs deps_file var_return pkg
	local var_return="$1"
	local pkg="$2"
	local pkg_cache_dir
	local _depfile

	get_pkg_cache_dir pkg_cache_dir "${pkg}"
	_depfile="${pkg_cache_dir}/deps"

	if [ ! -f "${_depfile}" ]; then
		if [ "${PKG_EXT}" = "tbz" ]; then
			injail tar -qxf "/packages/All/${pkg##*/}" -O +CONTENTS | awk '$1 == "@pkgdep" { print $2 }' > "${_depfile}"
		else
			injail ${PKG_BIN} info -qdF "/packages/All/${pkg##*/}" > "${_depfile}"
		fi
	fi

	setvar "${var_return}" "${_depfile}"
}

pkg_get_origin() {
	[ $# -lt 2 ] && eargs pkg_get_origin var_return pkg [origin]
	local var_return="$1"
	local pkg="$2"
	local _origin=$3
	local pkg_cache_dir
	local originfile
	local new_origin

	get_pkg_cache_dir pkg_cache_dir "${pkg}"
	originfile="${pkg_cache_dir}/origin"

	if [ ! -f "${originfile}" ]; then
		if [ -z "${_origin}" ]; then
			if [ "${PKG_EXT}" = "tbz" ]; then
				_origin=$(injail tar -qxf "/packages/All/${pkg##*/}" -O +CONTENTS | \
					awk -F: '$1 == "@comment ORIGIN" { print $2 }')
			else
				_origin=$(injail ${PKG_BIN} query -F \
					"/packages/All/${pkg##*/}" "%o")
			fi
		fi
		echo ${_origin} > "${originfile}"
	else
		read_line _origin "${originfile}"
	fi

	check_moved new_origin "${_origin}" && _origin=${new_origin}

	setvar "${var_return}" "${_origin}"

	[ -n "${_origin}" ]
}

pkg_get_dep_origin() {
	[ $# -ne 2 ] && eargs pkg_get_dep_origin var_return pkg
	local var_return="$1"
	local pkg="$2"
	local dep_origin_file
	local pkg_cache_dir
	local compiled_dep_origins
	local origin new_origin _old_dep_origins

	get_pkg_cache_dir pkg_cache_dir "${pkg}"
	dep_origin_file="${pkg_cache_dir}/dep_origin"

	if [ ! -f "${dep_origin_file}" ]; then
		if [ "${PKG_EXT}" = "tbz" ]; then
			compiled_dep_origins=$(injail tar -qxf "/packages/All/${pkg##*/}" -O +CONTENTS | \
				awk -F: '$1 == "@comment DEPORIGIN" {print $2}' | tr '\n' ' ')
		else
			compiled_dep_origins=$(injail ${PKG_BIN} query -F \
				"/packages/All/${pkg##*/}" '%do' | tr '\n' ' ')
		fi
		echo "${compiled_dep_origins}" > "${dep_origin_file}"
	else
		while read line; do
			compiled_dep_origins="${compiled_dep_origins} ${line}"
		done < "${dep_origin_file}"
	fi

	# Check MOVED
	_old_dep_origins="${compiled_dep_origins}"
	compiled_dep_origins=
	for origin in ${_old_dep_origins}; do
		if check_moved new_origin "${origin}"; then
			compiled_dep_origins="${compiled_dep_origins} ${new_origin}"
		else
			compiled_dep_origins="${compiled_dep_origins} ${origin}"
		fi
	done

	setvar "${var_return}" "${compiled_dep_origins}"
}

pkg_get_options() {
	[ $# -ne 2 ] && eargs pkg_get_options var_return pkg
	local var_return="$1"
	local pkg="$2"
	local optionsfile
	local pkg_cache_dir
	local _compiled_options

	get_pkg_cache_dir pkg_cache_dir "${pkg}"
	optionsfile="${pkg_cache_dir}/options"

	if [ ! -f "${optionsfile}" ]; then
		if [ "${PKG_EXT}" = "tbz" ]; then
			_compiled_options=$(injail tar -qxf "/packages/All/${pkg##*/}" -O +CONTENTS | \
				awk -F: '$1 == "@comment OPTIONS" {print $2}' | tr ' ' '\n' | \
				sed -n 's/^\+\(.*\)/\1/p' | sort | tr '\n' ' ')
		else
			_compiled_options=
			while read key value; do
				case "${value}" in
					off|false) continue ;;
				esac
				_compiled_options="${_compiled_options}${_compiled_options:+ }${key}"
			done <<-EOF
			$(injail ${PKG_BIN} query -F "/packages/All/${pkg##*/}" '%Ok %Ov' | sort)
			EOF
			# Compat with pretty-print-config
			if [ -n "${_compiled_options}" ]; then
				_compiled_options="${_compiled_options} "
			fi
		fi
		echo "${_compiled_options}" > "${optionsfile}"
		setvar "${var_return}" "${_compiled_options}"
		return 0
	fi

	# Special care here to match whitespace of 'pretty-print-config'
	while read line; do
		_compiled_options="${_compiled_options}${_compiled_options:+ }${line}"
	done < "${optionsfile}"

	# Space on end to match 'pretty-print-config' in delete_old_pkg
	[ -n "${_compiled_options}" ] &&
	    _compiled_options="${_compiled_options} "
	setvar "${var_return}" "${_compiled_options}"
}

ensure_pkg_installed() {
	local force="$1"
	local mnt

	_my_path mnt
	[ -z "${force}" ] && [ -x "${mnt}${PKG_BIN}" ] && return 0
	# Hack, speed up QEMU usage on pkg-repo.
	if [ ${QEMU_EMULATING} -eq 1 ] && \
	    [ -f /usr/local/sbin/pkg-static ]; then
		cp -f /usr/local/sbin/pkg-static "${mnt}/.p/pkg-static"
		return 0
	fi
	[ -e ${MASTERMNT}/packages/Latest/pkg.txz ] || return 1 #pkg missing
	injail tar xf /packages/Latest/pkg.txz -C / \
		-s ",/.*/,.p/,g" "*/pkg-static"
	return 0
}

pkg_cache_data() {
	[ $# -ne 2 ] && eargs pkg_cache_data pkg origin
	local pkg="$1"
	local origin="$2"

	ensure_pkg_installed || return 1
	pkg_get_options _ignored "${pkg}" > /dev/null
	pkg_get_origin _ignored "${pkg}" "${origin}" > /dev/null
	pkg_get_dep_origin _ignored "${pkg}" > /dev/null
	deps_file _ignored "${pkg}" > /dev/null
}

pkg_cacher_queue() {
	[ $# -eq 2 ] || eargs pkg_cacher_queue origin pkgname
	local origin="$1"
	local pkgname="$2"

	echo "${origin} ${pkgname}" > ${MASTERMNT}/.p/pkg_cacher.pipe
}

pkg_cacher_main() {
	local pkg pkgname origin work

	mkfifo ${MASTERMNT}/.p/pkg_cacher.pipe
	exec 6<> ${MASTERMNT}/.p/pkg_cacher.pipe

	trap exit TERM
	trap pkg_cacher_cleanup EXIT

	# Wait for packages to process.
	while :; do
		read -r work <&6
		set -- ${work}
		origin="$1"
		pkgname="$2"
		pkg="${PACKAGES}/All/${pkgname}.${PKG_EXT}"
		if [ -f "${pkg}" ]; then
			pkg_cache_data "${pkg}" "${origin}"
		fi
	done
}

pkg_cacher_cleanup() {
	rm -f ${MASTERMNT}/.p/pkg_cacher.pipe
}

get_cache_dir() {
	local var_return="$1"
	setvar "${var_return}" ${POUDRIERE_DATA}/cache/${MASTERNAME}
}

# Return the cache dir for the given pkg
# @param var_return The variable to set the result in
# @param string pkg $PKGDIR/All/PKGNAME.PKG_EXT
get_pkg_cache_dir() {
	[ $# -lt 2 ] && eargs get_pkg_cache_dir var_return pkg
	local var_return="$1"
	local pkg="$2"
	local use_mtime="${3:-1}"
	local pkg_file="${pkg##*/}"
	local pkg_dir
	local cache_dir
	local pkg_mtime=

	get_cache_dir cache_dir

	[ ${use_mtime} -eq 1 ] && pkg_mtime=$(stat -f %m "${pkg}")

	pkg_dir="${cache_dir}/${pkg_file}/${pkg_mtime}"

	if [ ${use_mtime} -eq 1 ]; then
		[ -d "${pkg_dir}" ] || mkdir -p "${pkg_dir}"
	fi

	setvar "${var_return}" "${pkg_dir}"
}

clear_pkg_cache() {
	[ $# -ne 1 ] && eargs clear_pkg_cache pkg
	local pkg="$1"
	local pkg_cache_dir

	get_pkg_cache_dir pkg_cache_dir "${pkg}" 0

	rm -fr "${pkg_cache_dir}"
}

delete_pkg() {
	[ $# -ne 1 ] && eargs delete_pkg pkg
	local pkg="$1"

	# Delete the package and the depsfile since this package is being deleted,
	# which will force it to be recreated
	rm -f "${pkg}"
	clear_pkg_cache "${pkg}"
}

# Deleted cached information for stale packages (manually removed)
delete_stale_pkg_cache() {
	local pkgname
	local cache_dir

	get_cache_dir cache_dir

	msg_verbose "Checking for stale cache files"

	[ ! -d ${cache_dir} ] && return 0
	dirempty ${cache_dir} && return 0
	for pkg in ${cache_dir}/*.${PKG_EXT}; do
		pkg_file="${pkg##*/}"
		# If this package no longer exists in the PKGDIR, delete the cache.
		[ ! -e "${PACKAGES}/All/${pkg_file}" ] &&
			clear_pkg_cache "${pkg}"
	done

	return 0
}

delete_old_pkg() {
	[ $# -eq 1 ] || eargs delete_old_pkg pkgname
	local pkg="$1"
	local mnt pkgname new_pkgname
	local origin v v2 compiled_options current_options current_deps compiled_deps

	pkgname="${pkg##*/}"
	pkgname="${pkgname%.*}"
	pkg_is_needed "${pkgname}" || return 0

	pkg_get_origin origin "${pkg}"
	_my_path mnt

	if [ ! -d "${mnt}${PORTSDIR}/${origin}" ]; then
		msg "${origin} does not exist anymore. Deleting stale ${pkg##*/}"
		delete_pkg "${pkg}"
		return 0
	fi

	v="${pkgname##*-}"
	if ! shash_get origin-pkgname "${origin}" new_pkgname; then
		# This origin was not looked up in gather_port_vars.  It is
		# a stale package with the same PKGBASE as one we want, but
		# with a different origin.  Such as lang/perl5.20 vs
		# lang/perl5.22 both with 'perl5' as PKGBASE.  A pkgclean
		# would handle removing this.
		msg "Deleting ${pkg##*/}: stale package: unwanted origin ${origin}"
		delete_pkg "${pkg}"
		return 0
	fi

	v2=${new_pkgname##*-}
	if [ "$v" != "$v2" ]; then
		msg "Deleting ${pkg##*/}: new version: ${v2}"
		delete_pkg "${pkg}"
		return 0
	fi

	# Detect ports that have new dependencies that the existing packages
	# do not have and delete them.
	if [ "${CHECK_CHANGED_DEPS}" != "no" ]; then
		current_deps=""
		liblist=""
		# FIXME: Move into Infrastructure/scripts and 
		# 'make actual-run-depends-list' after enough testing,
		# which will avoida all of the injail hacks

		for td in lib run; do
			shash_get pkgname-${td}_deps "${new_pkgname}" raw_deps || raw_deps=
			for d in ${raw_deps}; do
				key=${d%:*}
				dpath=${d#*:}
				case "${dpath}" in
				${PORTSDIR}/*) dpath=${dpath#${PORTSDIR}/} ;;
				esac
				case ${td} in
				lib)
					[ -n "${liblist}" ] || liblist=$(injail ldconfig -r | awk '$1 ~ /:-l/ { gsub(/.*-l/, "", $1); printf("%s ",$1) } END { printf("\n") }')
					case ${key} in
					lib*)
						unset found
						for dir in /lib /usr/lib ; do
							if injail test -f "${dir}/${key}"; then
								found=yes
								break;
							fi
						done
						[ -n "${found}" ] || current_deps="${current_deps} ${dpath}"
						;;
					*.*)
						case " ${liblist} " in
							*\ ${key}\ *) ;;
							*) current_deps="${current_deps} ${dpath}" ;;
						esac
						;;
					*)
						unset found
						for dir in /lib /usr/lib ; do
							if injail test -f "${dir}/lib${key}.so"; then
								found=yes
								break;
							fi
						done
						[ -n "${found}" ] || current_deps="${current_deps} ${dpath}"
						;;
					esac
					;;
				run)
					case $key in
					/*) [ -e ${mnt}/${key} ] || current_deps="${current_deps} ${dpath}" ;;
					*) [ -n "$(injail which ${key})" ] || current_deps="${current_deps} ${dpath}" ;;
					esac
					;;
				esac
			done
		done
		pkg_get_dep_origin compiled_deps "${pkg}"

		for d in ${current_deps}; do
			case " $compiled_deps " in
			*\ $d\ *) ;;
			*)
				msg "Deleting ${pkg##*/}: new dependency: ${d}"
				delete_pkg "${pkg}"
				return 0
				;;
			esac
		done
	fi

	# Check if the compiled options match the current options from make.conf and /var/db/ports
	if [ "${CHECK_CHANGED_OPTIONS}" != "no" ]; then
		if [ ${PORTS_HAS_SELECTED_OPTIONS} -eq 1 ]; then
			shash_get pkgname-options "${new_pkgname}" \
			    current_options || current_options=
			# pretty-print-config has a trailing space, so
			# pkg_get_options does as well.  Add in for compat.
			if [ -n "${current_options}" ]; then
				current_options="${current_options} "
			fi
		else
			# Backwards-compat
			current_options=$(injail /usr/bin/make -C \
			    ${PORTSDIR}/${origin} \
			    pretty-print-config | tr ' ' '\n' | \
			    sed -n 's/^\+\(.*\)/\1/p' | sort -u | tr '\n' ' ')
		fi
		pkg_get_options compiled_options "${pkg}"

		if [ "${compiled_options}" != "${current_options}" ]; then
			msg "Deleting ${pkg##*/}: changed options"
			if [ "${CHECK_CHANGED_OPTIONS}" = "verbose" ]; then
				msg "Pkg: ${compiled_options}"
				msg "New: ${current_options}"
			fi
			delete_pkg "${pkg}"
			return 0
		fi
	fi

	# XXX: Check if the pkgname has changed and rename in the repo
	if [ "${pkgname%-*}" != "${new_pkgname%-*}" ]; then
		msg "Deleting ${pkg##*/}: package name changed to '${new_pkgname%-*}'"
		delete_pkg "${pkg}"
		return 0
	fi
}

delete_old_pkgs() {

	msg "Checking packages for incremental rebuild needed"

	package_dir_exists_and_has_packages || return 0

	parallel_start
	for pkg in ${PACKAGES}/All/*.${PKG_EXT}; do
		parallel_run delete_old_pkg "${pkg}"
	done
	parallel_stop
}

## Pick the next package from the "ready to build" queue in pool/
## Then move the package to the "building" dir in building/
## This is only ran from 1 process
next_in_queue() {
	[ "${PWD}" = "${MASTERMNT}/.p/pool" ] || \
	    err 1 "next_in_queue requires PWD=${MASTERMNT}/.p/pool"
	local var_return="$1"
	local p _pkgname ret

	# CWD is MASTERMNT/.p/pool

	p=$(find ${POOL_BUCKET_DIRS} -type d -depth 1 -empty -print -quit || :)
	if [ -n "$p" ]; then
		_pkgname=${p##*/}
		if ! rename "${p}" "../building/${_pkgname}" \
		    2>/dev/null; then
			# Was the failure from /unbalanced?
			if [ -z "${p%%*unbalanced/*}" ]; then
				# We lost the race with a child running
				# balance_queue(). The file is already
				# gone and moved to a bucket. Try again.
				ret=0
				next_in_queue "${var_return}" || ret=$?
				return ${ret}
			else
				# Failure to move a balanced item??
				err 1 "next_in_queue: Failed to mv ${p} to ${MASTERMNT}/.p/building/${_pkgname}"
			fi
		fi
		# Update timestamp for buildtime accounting
		touch "../building/${_pkgname}"
	fi

	setvar "${var_return}" "${_pkgname}"
}

lock_acquire() {
	[ $# -ge 1 ] || eargs lock_acquire lockname [waittime]
	local lockname="$1"
	local waittime="${2:-30}"

	# Don't take locks inside siginfo_handler
	[ ${in_siginfo_handler} -eq 1 ] && lock_have "${lockname}" && \
	    return 1

	if ! locked_mkdir "${waittime}" \
	    "${POUDRIERE_TMPDIR}/lock-${MASTERNAME}-${lockname}"; then
		msg_warn "Failed to acquire ${lockname} lock"
		return 1
	fi
	hash_set have_lock "${lockname}" 1

	# Delay TERM/INT while holding the lock
	critical_start
}

lock_release() {
	[ $# -ne 1 ] && eargs lock_release lockname
	local lockname="$1"

	hash_unset have_lock "${lockname}" || \
	    err 1 "Releasing unheld lock ${lockname}"
	rmdir "${POUDRIERE_TMPDIR}/lock-${MASTERNAME}-${lockname}" 2>/dev/null

	# Restore and deliver INT/TERM signals
	critical_end
}

lock_have() {
	[ $# -ne 1 ] && eargs lock_have lockname
	local lockname="$1"
	local _ignored

	hash_get have_lock "${lockname}" _ignored
}

# Fetch vars from the Makefile and set them locally.
# port_var_fetch ports-mgmt/pkg PKGNAME pkgname PKGBASE pkgbase ...
# Assignments are supported as well, without a subsequent variable for storage.
port_var_fetch() {
	local -; set +x
	[ $# -ge 3 ] || eargs port_var_fetch origin PORTVAR var_set ...
	local origin="$1"
	local _makeflags _vars
	local _portvar _var _line _errexit shiftcnt varcnt
	# Use a tab rather than space to allow FOO='BLAH BLAH' assignments
	# and lookups like -V'${PKG_DEPENDS} ${BUILD_DEPENDS}'
	local IFS sep=$'\t'
	# Use invalid shell var character '!' to ensure we
	# don't setvar it later.
	local assign_var="!"

	shift

	while [ $# -ge 2 ]; do
		_portvar="$1"
		_var="$2"
		if [ -z "${_portvar%%*=*}" ]; then
			# This is an assignment, no associated variable
			# for storage.
			_makeflags="${_makeflags}${_makeflags:+${sep}}${_portvar}"
			_vars="${_vars}${_vars:+ }${assign_var}"
			shift 1
		else
			_makeflags="${_makeflags}${_makeflags:+${sep}}-V${_portvar}"
			_vars="${_vars}${_vars:+ }${_var}"
			shift 2
		fi
	done

	[ $# -eq 0 ] || eargs port_var_fetch origin PORTVAR var_set ...

	_errexit="!errexit!"
	ret=0

	set -- ${_vars}
	varcnt=$#
	shiftcnt=0
	while read -r _line; do
		if [ "${_line% *}" = "${_errexit}" ]; then
			ret=${_line#* }
			# Encountered an error, abort parsing anything further.
			# Cleanup already-set vars of 'make: stopped in'
			# stuff in case the caller is ignoring our non-0
			# return status.  The shiftcnt handler can deal with
			# this all itself.
			shiftcnt=0
			break
		fi
		# This var was just an assignment, no actual value to read from
		# stdout.  Shift until we find an actual -V var.
		while [ "${1}" = "${assign_var}" ]; do
			shift
			shiftcnt=$((shiftcnt + 1))
		done
		# We may have more lines than expected on an error, but our
		# errexit output is last, so keep reading until then.
		if [ $# -gt 0 ]; then
			setvar "$1" "${_line}" || return $?
			shift
			shiftcnt=$((shiftcnt + 1))
		fi
	done <<-EOF
	$(IFS="${sep}"; injail /usr/bin/make -C "${PORTSDIR}/${origin}" ${_makeflags} || echo "${_errexit} $?")
	EOF

	# If the entire output was blank, then $() ate all of the excess
	# newlines, which resulted in some vars not getting setvar'd.
	# This could also be cleaning up after the errexit case.
	if [ ${shiftcnt} -ne ${varcnt} ]; then
		set -- ${_vars}
		# Be sure to start at the last setvar'd value.
		if [ ${shiftcnt} -gt 0 ]; then
			shift ${shiftcnt}
		fi
		while [ $# -gt 0 ]; do
			# Skip assignment vars
			while [ "${1}" = "${assign_var}" ]; do
				shift
			done
			setvar "$1" "" || return $?
			shift
		done
	fi

	return ${ret}
}

cache_get_origin() {
	[ $# -ne 2 ] && eargs cache_get_origin var_return pkgname
	local var_return="$1"
	local pkgname="$2"
	local _origin

	shash_get pkgname-origin "${pkgname}" _origin

	setvar "${var_return}" "${_origin}"
}

set_dep_fatal_error() {
	[ -n "${DEP_FATAL_ERROR}" ] && return 0
	DEP_FATAL_ERROR=1
	# Mark the fatal error flag. Must do it like this as this may be
	# running in a sub-shell.
	: > dep_fatal_error
}

clear_dep_fatal_error() {
	unset DEP_FATAL_ERROR
	rm -f dep_fatal_error 2>/dev/null || :
}

check_dep_fatal_error() {
	[ -n "${DEP_FATAL_ERROR}" ] || [ -f dep_fatal_error ]
}

gather_port_vars() {
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "gather_port_vars requires PWD=${MASTERMNT}/.p"
	local origin qorigin

	# A. Lookup all port vars/deps from the given list of ports.
	# B. For every dependency found (depqueue):
	#   1. Add it into the depqueue, which will then process
	#      each dependency into the gatherqueue if it was not
	#      already gathered by the previous iteration.
	# C. Lookup all port vars/deps from the gatherqueue
	# D. If the depqueue is empty, done, otherwise go to B.
	#
	# This 2-queue solution is to avoid excessive races that cause
	# make -V to be ran multiple times per port.  We only want to
	# process each port once without explicit locking.
	# For the -a case the depqueue is not needed since all ports will be
	# visited once in the first pass and make it into the gatherqueue.

	msg "Gathering ports metadata"
	bset status "gatheringportvars:"

	:> "all_pkgs"
	[ ${ALL} -eq 0 ] && :> "all_pkgbases"

	rm -rf gqueue dqueue 2>/dev/null || :
	mkdir gqueue dqueue

	clear_dep_fatal_error
	parallel_start
	for origin in $(listed_ports show_moved); do
		if [ -d "../${PORTSDIR}/${origin}" ]; then
			parallel_run \
			prefix_stderr_quick \
			"(${COLOR_PORT}${origin}${COLOR_RESET})${COLOR_WARN}" \
			gather_port_vars_port "${origin}" || \
			    set_dep_fatal_error
		else
			if [ ${ALL} -eq 1 ]; then
				msg_warn "Nonexistent origin listed in category Makefiles: ${COLOR_PORT}${origin}"
			else
				msg_error "Nonexistent origin listed for build: ${COLOR_PORT}${origin}"
				set_dep_fatal_error
			fi
		fi
	done
	if ! parallel_stop || check_dep_fatal_error; then
		err 1 "Fatal errors encountered gathering initial ports metadata"
	fi

	until dirempty dqueue && dirempty gqueue; do
		# Process all newly found deps into the gatherqueue
		clear_dep_fatal_error
		msg_debug "Processing depqueue"
		parallel_start
		for qorigin in dqueue/*; do
			case "${qorigin}" in
				"dqueue/*") break ;;
			esac
			parallel_run \
			    gather_port_vars_process_depqueue "${qorigin}" || \
			    set_dep_fatal_error
		done
		if ! parallel_stop || check_dep_fatal_error; then
			err 1 "Fatal errors encountered processing gathered ports metadata"
		fi

		# Now process the gatherqueue

		# Now rerun until the work queue is empty
		# XXX: If the initial run were to use an efficient work queue then
		#      this could be avoided.
		clear_dep_fatal_error
		parallel_start
		msg_debug "Processing gatherqueue"
		for qorigin in gqueue/*; do
			case "${qorigin}" in
				"gqueue/*") break ;;
			esac
			origin="${qorigin#*/}"
			origin="${origin%!*}/${origin#*!}"
			parallel_run \
			    prefix_stderr_quick \
			    "(${COLOR_PORT}${origin}${COLOR_RESET})${COLOR_WARN}" \
			    gather_port_vars_port \
			    "${origin}" inqueue || set_dep_fatal_error
		done
		if ! parallel_stop || check_dep_fatal_error; then
			err 1 "Fatal errors encountered gathering ports metadata"
		fi
	done

	if ! rmdir gqueue || ! rmdir dqueue; then
		ls gqueue dqueue 2>/dev/null || :
		err 1 "Gather port queues not empty"
	fi
}

gather_port_vars_port() {
	[ "${SHASH_VAR_PATH}" = "var/cache" ] || \
	    err 1 "gather_port_vars_port requires SHASH_VAR_PATH=var/cache"
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "gather_port_vars_port requires PWD=${MASTERMNT}/.p"
	[ $# -lt 1 ] && eargs gather_port_vars_port origin [inqueue]
	[ $# -gt 2 ] && eargs gather_port_vars_port origin [inqueue]
	local origin="$1"
	local inqueue="$2"
	local dep_origin deps pkgname

	msg_debug "gather_port_vars_port (${origin}): LOOKUP"
	# Remove queue entry
	[ -n "${inqueue}" ] && rmdir "gqueue/${origin%/*}!${origin#*/}"

	shash_get origin-pkgname "${origin}" pkgname && \
	    err 1 "gather_port_vars_port: Already had ${origin}"

	if ! deps_fetch_vars "${origin}" deps pkgname; then
		# An error is printed from deps_fetch_vars
		set_dep_fatal_error
		return 1
	fi

	echo "${pkgname}" >> "all_pkgs"
	[ ${ALL} -eq 0 ] && echo "${pkgname%-*}" >> "all_pkgbases"

	# If there are no deps for this port then there's nothing left to do.
	[ -z "${deps}" ] && return 0

	# Assert some policy before proceeding to process these deps
	# further.
	for dep_origin in ${deps}; do
		msg_verbose "${COLOR_PORT}${origin}${COLOR_DEBUG} depends on ${COLOR_PORT}${dep_origin}"
		if [ "${origin}" = "${dep_origin}" ]; then
			msg_error "${COLOR_PORT}${origin}${COLOR_RESET} incorrectly depends on itself. Please contact maintainer of the port to fix this."
			set_dep_fatal_error
			return 1
		fi
		# Detect bad cat/origin/ dependency which pkg will not register properly
		if ! [ "${dep_origin}" = "${dep_origin%/}" ]; then
			msg_error "${COLOR_PORT}${origin}${COLOR_RESET} depends on bad origin '${COLOR_PORT}${dep_origin}${COLOR_RESET}'; Please contact maintainer of the port to fix this."
			set_dep_fatal_error
			return 1
		fi
		if ! [ -d "../${PORTSDIR}/${dep_origin}" ]; then
			msg_error "${COLOR_PORT}${origin}${COLOR_RESET} depends on nonexistent origin '${COLOR_PORT}${dep_origin}${COLOR_RESET}'; Please contact maintainer of the port to fix this."
			set_dep_fatal_error
			return 1
		fi
	done

	# In the -a case, there's no need to gather the vars for these deps
	# since we are going to visit all ports from the category Makefiles
	# anyway.
	if [ ${ALL} -eq 0 ]; then
		msg_debug "gather_port_vars_port (${origin}): Adding to depqueue"
		mkdir "dqueue/${origin%/*}!${origin#*/}" || \
			err 1 "gather_port_vars_port: Failed to add ${origin} to depqueue"
	fi
}

gather_port_vars_process_depqueue() {
	[ "${SHASH_VAR_PATH}" = "var/cache" ] || \
	    err 1 "gather_port_vars_process_depqueue requires SHASH_VAR_PATH=var/cache"
	[ $# -ne 1 ] && eargs gather_port_vars_process_depqueue qorigin
	local qorigin="$1"
	local origin pkgname deps dep_origin dep_pkgname

	origin="${qorigin#*/}"
	origin="${origin%!*}/${origin#*!}"

	msg_debug "gather_port_vars_process_depqueue (${origin})"
	# Remove queue entry
	rmdir "${qorigin}"

	# Add all of this origin's deps into the gatherqueue to reprocess
	shash_get origin-pkgname "${origin}" pkgname || \
	    err 1 "gather_port_vars_process_depqueue failed to find pkgname for origin ${origin}"
	shash_get pkgname-deps "${pkgname}" deps || \
	    err 1 "gather_port_vars_process_depqueue failed to find deps for pkg ${pkgname}"

	for dep_origin in ${deps}; do
		# Add this origin into the gatherqueue if not already done.
		if ! shash_get origin-pkgname "${dep_origin}" dep_pkgname; then
			msg_debug "gather_port_vars_process_depqueue (${origin}): Adding ${dep_origin} into the gatherqueue"
			# Another worker may have created it
			mkdir "gqueue/${dep_origin%/*}!${dep_origin#*/}" \
			    2>/dev/null || :
		fi
	done
}


compute_deps() {
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "compute_deps requires PWD=${MASTERMNT}/.p"
	local pkgname dep_pkgname

	msg "Calculating ports order and dependencies"
	bset status "computingdeps:"

	:> "pkg_deps.unsorted"

	clear_dep_fatal_error
	parallel_start
	while read pkgname; do
		parallel_run compute_deps_pkg "${pkgname}" || \
			set_dep_fatal_error
	done < "all_pkgs"
	if ! parallel_stop || check_dep_fatal_error; then
		err 1 "Fatal errors encountered calculating dependencies"
	fi

	sort -u "pkg_deps.unsorted" > "pkg_deps"

	bset status "computingrdeps:"

	# cd into rdeps to allow xargs mkdir to have more args.
	(
		cd "rdeps"
		awk '{print $2}' "../pkg_deps" | sort -u | xargs mkdir
		awk '{print $2 "/" $1}' "../pkg_deps" | xargs touch
	)

	rm -f "pkg_deps.unsorted"

	return 0
}

compute_deps_pkg() {
	[ "${SHASH_VAR_PATH}" = "var/cache" ] || \
	    err 1 "compute_deps_pkg requires SHASH_VAR_PATH=var/cache"
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "compute_deps_pkgname requires PWD=${MASTERMNT}/.p"
	[ $# -lt 1 ] && eargs compute_deps_pkg pkgname
	local pkgname="$1"
	local pkg_pooldir deps dep_origin dep_pkgname

	shash_get pkgname-deps "${pkgname}" deps || \
	    err 1 "compute_deps_pkg failed to find deps for ${pkgname}"

	pkg_pooldir="deps/${pkgname}"
	mkdir "${pkg_pooldir}" || \
	    err 1 "compute_deps_pkg: Error creating pool dir for ${pkgname}: There may be a duplicate origin in a category Makefile"

	for dep_origin in ${deps}; do
		shash_get origin-pkgname "${dep_origin}" dep_pkgname || \
		    err 1 "compute_deps_pkg failed to lookup pkgname for ${dep_origin} processing package ${pkgname}"
		:> "${pkg_pooldir}/${dep_pkgname}"
		echo "${pkgname} ${dep_pkgname}" >> "pkg_deps.unsorted"
	done

	return 0
}

listed_ports() {
	local tell_moved="${1}"
	local portsdir origin file

	if [ ${ALL} -eq 1 ]; then
		_pget portsdir ${PTNAME} mnt
		[ -d "${portsdir}/ports" ] && portsdir="${portsdir}/ports"
		for cat in $(awk -F= '$1 ~ /^[[:space:]]*SUBDIR[[:space:]]*\+/ {gsub(/[[:space:]]/, "", $2); print $2}' ${portsdir}/Makefile); do
			awk -F= -v cat=${cat} '$1 ~ /^[[:space:]]*SUBDIR[[:space:]]*\+/ {gsub(/[[:space:]]/, "", $2); print cat"/"$2}' ${portsdir}/${cat}/Makefile
		done
		return 0
	fi

	{
		# -f specified
		if [ -z "${LISTPORTS}" ]; then
			for file in ${LISTPKGS}; do
				while read origin; do
					# Skip blank lines and comments
					[ -z "${origin%%#*}" ] && continue
					# Remove trailing slash for historical reasons.
					echo "${origin%/}"
				done < "${file}"
			done
		else
			# Ports specified on cmdline
			for origin in ${LISTPORTS}; do
				# Remove trailing slash for historical reasons.
				echo "${origin%/}"
			done
		fi
	} | sort -u | while read origin; do
		if check_moved new_origin ${origin}; then
			[ -n "${tell_moved}" ] && msg \
			    "MOVED: ${COLOR_PORT}${origin}${COLOR_RESET} renamed to ${COLOR_PORT}${new_origin}${COLOR_RESET}" >&2
			origin="${new_origin}"
		fi
		echo "${origin}"
	done
}

# Port was requested to be built
port_is_listed() {
	[ $# -eq 1 ] || eargs port_is_listed origin
	local origin="$1"

	if [ ${ALL} -eq 1 -o ${PORTTESTING_RECURSIVE} -eq 1 ]; then
		return 0
	fi

	listed_ports | grep -q "^${origin}\$" && return 0

	return 1
}

# Port was requested to be built, or is needed by a port requested to be built
pkg_is_needed() {
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "pkg_is_needed requires PWD=${MASTERMNT}/.p"
	[ $# -eq 1 ] || eargs pkg_is_needed pkgname
	local pkgname="$1"
	local pkgbase

	[ ${ALL} -eq 1 ] && return 0

	# We check on PKGBASE rather than PKGNAME from pkg_deps
	# since the caller may be passing in a different version
	# compared to what is in the queue to build for.
	pkgbase="${pkgname%-*}"

	awk -vpkgbase="${pkgbase}" '
	    $1 == pkgbase {
		found=1
		exit 0
	    }
	    END {
		if (found != 1)
			exit 1
	    }' "all_pkgbases"
}

get_porttesting() {
	[ $# -eq 1 ] || eargs get_porttesting pkgname
	local pkgname="$1"
	local porttesting
	local origin

	if [ -n "${PORTTESTING}" ]; then
		cache_get_origin origin "${pkgname}"
		if port_is_listed "${origin}"; then
			porttesting=1
		fi
	fi

	echo $porttesting
}

find_all_deps() {
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "find_all_deps requires PWD=${MASTERMNT}/.p"
	[ $# -ne 1 ] && eargs find_all_deps pkgname
	local pkgname="$1"
	local dep_pkgname

	FIND_ALL_DEPS="${FIND_ALL_DEPS} ${pkgname}"

	#msg_debug "find_all_deps ${pkgname}"

	# Show deps/*/${pkgname}
	for pn in deps/${pkgname}/*; do
		dep_pkgname=${pn##*/}
		case " ${FIND_ALL_DEPS} " in
			*\ ${dep_pkgname}\ *) continue ;;
		esac
		case "${pn}" in
			"deps/${pkgname}/*") break ;;
		esac
		echo "deps/${dep_pkgname}"
		find_all_deps "${dep_pkgname}"
	done
	echo "deps/${pkgname}"
}

find_all_pool_references() {
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "find_all_pool_references requires PWD=${MASTERMNT}/.p"
	[ $# -ne 1 ] && eargs find_all_pool_references pkgname
	local pkgname="$1"
	local rpn dep_pkgname

	# Cleanup rdeps/*/${pkgname}
	for rpn in deps/${pkgname}/*; do
		case "${rpn}" in
			"deps/${pkgname}/*")
				break ;;
		esac
		dep_pkgname=${rpn##*/}
		echo "rdeps/${dep_pkgname}/${pkgname}"
	done
	echo "deps/${pkgname}"
	# Cleanup deps/*/${pkgname}
	for rpn in rdeps/${pkgname}/*; do
		case "${rpn}" in
			"rdeps/${pkgname}/*")
				break ;;
		esac
		dep_pkgname=${rpn##*/}
		echo "deps/${dep_pkgname}/${pkgname}"
	done
	echo "rdeps/${pkgname}"
}

delete_stale_symlinks_and_empty_dirs() {
	msg_n "Deleting stale symlinks..."
	find -L ${PACKAGES} -type l \
		-exec rm -f {} +
	echo " done"

	msg_n "Deleting empty directories..."
	find ${PACKAGES} -type d -mindepth 1 \
		-empty -delete
	echo " done"
}

load_moved() {
	[ "${SHASH_VAR_PATH}" = "var/cache" ] || \
	    err 1 "load_moved requires SHASH_VAR_PATH=var/cache"
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "load_moved requires PWD=${MASTERMNT}/.p"
	[ -f ${MASTERMNT}${PORTSDIR}/MOVED ] || return 0
	msg "Loading MOVED"
	bset status "loading_moved:"
	grep -v '^#' ${MASTERMNT}${PORTSDIR}/MOVED | awk \
	    -F\| '
		$2 != "" {
			print $1,$2;
		}' | while read old_origin new_origin; do
			shash_set origin-moved "${old_origin}" "${new_origin}"
		done
}

check_moved() {
	[ $# -lt 2 ] && eargs check_moved var_return origin
	local var_return="$1"
	local origin="$2"

	shash_get origin-moved "${origin}" "${var_return}"
}

clean_build_queue() {
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "clean_build_queue requires PWD=${MASTERMNT}/.p"
	local tmp pn port

	bset status "cleaning:"
	msg "Cleaning the build queue"

	# Delete from the queue all that already have a current package.
	for pn in $(ls deps/); do
		[ -f "../packages/All/${pn}.${PKG_EXT}" ] && \
		    find_all_pool_references "${pn}"
	done | xargs rm -rf

	# Delete from the queue orphaned build deps. This can happen if
	# the specified-to-build ports have all their deps satisifed
	# but one of their run deps has missing build deps packages which
	# causes the build deps to be in the queue at this point.

	if [ ${TRIM_ORPHANED_BUILD_DEPS} = "yes" -a ${ALL} -eq 0 ]; then
		tmp=$(mktemp -t queue)
		{
			listed_ports | while read port; do
				shash_get origin-pkgname "${port}" pkgname || \
				    err 1 "Failed to lookup PKGNAME for ${port}"
				echo "${pkgname}"
			done
			# Pkg is a special case. It may not have been requested,
			# but it should always be rebuilt if missing.  The
			# origin-pkgname lookup may fail if it wasn't
			# in the build queue.
			for port in ports-mgmt/pkg ports-mgmt/pkg-devel; do
				shash_get origin-pkgname "${port}" pkgname && \
				    echo "${pkgname}"
			done
		} | {
			FIND_ALL_DEPS=
			while read pkgname; do
				find_all_deps "${pkgname}"
			done | sort -u > ${tmp}
		}
		find deps -type d -mindepth 1 -maxdepth 1 | \
		    sort > ${tmp}.actual
		comm -13 ${tmp} ${tmp}.actual | while read pd; do
			find_all_pool_references "${pd##*/}"
		done | xargs rm -rf
		rm -f ${tmp} ${tmp}.actual
	fi
}

# PWD will be MASTERMNT/.p after this
prepare_ports() {
	local pkg
	local log log_top
	local n pn nbq resuming_build
	local cache_dir sflag

	_log_path log
	mkdir -p "${MASTERMNT}/.p/building" \
		"${MASTERMNT}/.p/pool" \
		"${MASTERMNT}/.p/pool/unbalanced" \
		"${MASTERMNT}/.p/deps" \
		"${MASTERMNT}/.p/rdeps" \
		"${MASTERMNT}/.p/cleaning/deps" \
		"${MASTERMNT}/.p/cleaning/rdeps" \
		"${MASTERMNT}/.p/var/run" \
		"${MASTERMNT}/.p/var/cache"

	cd "${MASTERMNT}/.p"
	SHASH_VAR_PATH="var/cache"
	# No prefix needed since we're unique in MASTERMNT.
	SHASH_VAR_PREFIX=
	# Allow caching values now
	USE_CACHE_CALL=1

	if [ -e "${log}/.poudriere.ports.built" ]; then
		resuming_build=1
	else
		resuming_build=0
	fi

	if was_a_bulk_run; then
		_log_path_top log_top
		get_cache_dir cache_dir

		if [ ${resuming_build} -eq 0 ] || ! [ -d "${log}" ]; then
			# Sync in HTML files through a base dir
			install_html_files "${HTMLPREFIX}" "${log_top}/.html" \
			    "${log}"
			# Create log dirs
			mkdir -p ${log}/../../latest-per-pkg \
			    ${log}/../latest-per-pkg \
			    ${log}/logs \
			    ${log}/logs/errors \
			    ${cache_dir}
			# Link this build as the /latest
			ln -sfh ${BUILDNAME} ${log%/*}/latest

			# Record the SVN URL@REV in the build
			[ -d ${MASTERMNT}${PORTSDIR}/.svn ] && bset svn_url $(
				${SVN_CMD} info ${MASTERMNT}${PORTSDIR} | awk '
					/^URL: / {URL=substr($0, 6)}
					/Revision: / {REVISION=substr($0, 11)}
					END { print URL "@" REVISION }
				')

			bset mastername "${MASTERNAME}"
			bset jailname "${JAILNAME}"
			bset setname "${SETNAME}"
			bset ptname "${PTNAME}"
			bset buildname "${BUILDNAME}"
			bset started "${EPOCH_START}"
		fi

		show_log_info
		# Must acquire "update_stats" on shutdown to ensure
		# the process is not killed while holding it.
		if [ ${HTML_JSON_UPDATE_INTERVAL} -ne 0 ]; then
			coprocess_start html_json
		else
			msg "HTML UI updates are disabled by HTML_JSON_UPDATE_INTERVAL being 0"
		fi
	fi

	load_moved

	gather_port_vars

	compute_deps

	bset status "sanity:"

	if [ -f ${PACKAGES}/.jailversion ]; then
		if [ "$(cat ${PACKAGES}/.jailversion)" != \
		    "$(jget ${JAILNAME} version)" ]; then
			JAIL_NEEDS_CLEAN=1
		fi
	fi

	if was_a_bulk_run; then
		if [ ${JAIL_NEEDS_CLEAN} -eq 1 ]; then
			msg_n "Cleaning all packages due to newer version of the jail..."
		elif [ ${CLEAN} -eq 1 ]; then
			msg_n "(-c) Cleaning all packages..."
		fi

		if [ ${JAIL_NEEDS_CLEAN} -eq 1 ] || [ ${CLEAN} -eq 1 ]; then
			rm -rf ${PACKAGES}/* ${cache_dir}
			echo " done"
		fi

		if [ ${CLEAN_LISTED} -eq 1 ]; then
			msg "(-C) Cleaning specified ports to build"
			listed_ports | while read port; do
				shash_get origin-pkgname "${port}" pkgname || \
				    err 1 "Failed to lookup PKGNAME for ${port}"
				pkg="${PACKAGES}/All/${pkgname}.${PKG_EXT}"
				if [ -f "${pkg}" ]; then
					msg "(-C) Deleting existing package: ${pkg##*/}"
					delete_pkg "${pkg}"
				fi
			done
		fi

		# If the build is being resumed then packages already
		# built/failed/skipped/ignored should not be rebuilt.
		if [ ${resuming_build} -eq 1 ]; then
			awk '{print $2}' \
				${log}/.poudriere.ports.built \
				${log}/.poudriere.ports.failed \
				${log}/.poudriere.ports.ignored \
				${log}/.poudriere.ports.skipped | \
			while read pn; do
				find_all_pool_references "${pn}"
			done | xargs rm -rf
		else
			# New build
			bset stats_queued 0
			bset stats_built 0
			bset stats_failed 0
			bset stats_ignored 0
			bset stats_skipped 0
			:> ${log}/.data.json
			:> ${log}/.data.mini.json
			:> ${log}/.poudriere.ports.built
			:> ${log}/.poudriere.ports.failed
			:> ${log}/.poudriere.ports.ignored
			:> ${log}/.poudriere.ports.skipped
		fi
	fi

	if ! ensure_pkg_installed && [ ${SKIPSANITY} -eq 0 ]; then
		msg "pkg package missing, skipping sanity"
		SKIPSANITY=2
	fi

	if [ $SKIPSANITY -eq 0 ]; then
		msg "Sanity checking the repository"

		for n in repo.txz digests.txz packagesite.txz; do
			pkg="${PACKAGES}/All/${n}"
			if [ -f "${pkg}" ]; then
				msg "Removing invalid pkg repo file: ${pkg}"
				rm -f "${pkg}"
			fi

		done

		delete_stale_pkg_cache

		# Skip incremental build for pkgclean
		if was_a_bulk_run; then
			delete_old_pkgs

			if [ ${SKIP_RECURSIVE_REBUILD} -eq 0 ]; then
				msg_verbose "Checking packages for missing dependencies"
				while :; do
					sanity_check_pkgs && break
				done
			else
				msg "(-S) Skipping recursive rebuild"
			fi

			delete_stale_symlinks_and_empty_dirs
		fi
	else
		[ ${SKIPSANITY} -eq 1 ] && sflag="(-s) "
		msg "${sflag}Skipping incremental rebuild and repository sanity checks"
	fi

	export LOCALBASE=${LOCALBASE:-/usr/local}

	clean_build_queue

	# Call the deadlock code as non-fatal which will check for cycles
	sanity_check_queue 0

	if was_a_bulk_run && [ $resuming_build -eq 0 ]; then
		nbq=0
		nbq=$(find deps -type d -depth 1 | wc -l)
		# Add 1 for the main port to test
		[ "${SCRIPTPATH##*/}" = "testport.sh" ] && nbq=$((${nbq} + 1))
		bset stats_queued ${nbq##* }
	fi

	# Create a pool of ready-to-build from the deps pool
	find deps -type d -empty -depth 1 | \
		xargs -J % mv % pool/unbalanced
	load_priorities
	balance_pool

	[ -n "${ALLOW_MAKE_JOBS}" ] || echo "DISABLE_MAKE_JOBS=poudriere" \
	    >> ${MASTERMNT}/etc/make.conf
	# Don't leak ports-env UID as it conflicts with BUILD_AS_NON_ROOT
	if [ "${BUILD_AS_NON_ROOT}" = "yes" ]; then
		sed -i '' '/^UID=0$/d' "${MASTERMNT}/etc/make.conf"
		sed -i '' '/^GID=0$/d' "${MASTERMNT}/etc/make.conf"
		# Will handle manually for now on until build_port.
		export UID=0
		export GID=0
	fi

	jget ${JAILNAME} version > ${PACKAGES}/.jailversion

	return 0
}

load_priorities_tsortD() {
	local priority pkgname pkg_boost boosted origin
	local - # Keep set -f local

	tsort -D "pkg_deps" > "pkg_deps.depth"

	# Create buckets to satisfy the dependency chains, in reverse
	# order. Not counting here as there may be boosted priorities
	# at 99 or other high values.

	POOL_BUCKET_DIRS=$(awk '{print $1}' "pkg_deps.depth"|sort -run)

	set -f # for PRIORITY_BOOST
	boosted=0
	while read priority pkgname; do
		# Does this pkg have an override?
		for pkg_boost in ${PRIORITY_BOOST}; do
			case ${pkgname%-*} in
				${pkg_boost})
					[ -d "deps/${pkgname}" ] \
					    || continue
					cache_get_origin origin "${pkgname}"
					msg "Boosting priority: ${COLOR_PORT}${origin}"
					priority=${PRIORITY_BOOST_VALUE}
					boosted=1
					break
					;;
			esac
		done
		hash_set "priority" "${pkgname}" ${priority}
	done < "pkg_deps.depth"

	# Add ${PRIORITY_BOOST_VALUE} into the pool if needed.
	[ ${boosted} -eq 1 ] && POOL_BUCKET_DIRS="${PRIORITY_BOOST_VALUE} ${POOL_BUCKET_DIRS}"

	return 0
}

load_priorities_ptsort() {
	local priority pkgname pkg_boost origin
	local - # Keep set -f local

	set -f # for PRIORITY_BOOST

	awk '{print $2 " " $1}' "pkg_deps" > "pkg_deps.ptsort"

	# Add in boosts before running ptsort
	while read pkgname; do
		# Does this pkg have an override?
		for pkg_boost in ${PRIORITY_BOOST}; do
			case ${pkgname%-*} in
				${pkg_boost})
					[ -d "deps/${pkgname}" ] \
					    || continue
					cache_get_origin origin "${pkgname}"
					msg "Boosting priority: ${COLOR_PORT}${origin}"
					echo "${pkgname} ${PRIORITY_BOOST_VALUE}" >> \
					    "pkg_deps.ptsort"
					break
					;;
			esac
		done
	done < "all_pkgs"

	ptsort -p "pkg_deps.ptsort" > \
	    "pkg_deps.priority"

	# Create buckets to satisfy the dependency chain priorities.
	POOL_BUCKET_DIRS=$(awk '{print $1}' \
	    "pkg_deps.priority"|sort -run)

	# Read all priorities into the "priority" hash
	while read priority pkgname; do
		hash_set "priority" "${pkgname}" ${priority}
	done < "pkg_deps.priority"

	return 0
}

load_priorities() {
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "load_priorities requires PWD=${MASTERMNT}/.p"

	POOL_BUCKET_DIRS=""

	if [ ${POOL_BUCKETS} -gt 0 ]; then
		if [ "${USE_PTSORT}" = "yes" ]; then
			load_priorities_ptsort
		else
			load_priorities_tsortD
		fi
	fi

	# If there are no buckets then everything to build will fall
	# into 0 as they depend on nothing and nothing depends on them.
	# I.e., pkg-devel in -ac or testport on something with no deps
	# needed.
	[ -z "${POOL_BUCKET_DIRS}" ] && POOL_BUCKET_DIRS="0"

	# Create buckets after loading priorities in case of boosts.
	( cd pool && mkdir ${POOL_BUCKET_DIRS} )

	# unbalanced is where everything starts at.  Items are moved in
	# balance_pool based on their priority in the "priority" hash.
	POOL_BUCKET_DIRS="${POOL_BUCKET_DIRS} unbalanced"

	return 0
}

balance_pool() {
	# Don't bother if disabled
	[ ${POOL_BUCKETS} -gt 0 ] || return 0
	[ "${PWD}" = "${MASTERMNT}/.p" ] || \
	    err 1 "balance_pool requires PWD=${MASTERMNT}/.p"

	local pkgname pkg_dir dep_count lock

	# Avoid running this in parallel, no need. Note that this lock is
	# not on the unbalanced/ dir, but only this function. clean.sh writes
	# to unbalanced/, queue_empty() reads from it, and next_in_queue()
	# moves from it.
	lock=.lock-balance_pool
	mkdir ${lock} 2>/dev/null || return 0

	if dirempty pool/unbalanced; then
		rmdir ${lock}
		return 0
	fi

	if [ -n "${MY_JOBID}" ]; then
		bset ${MY_JOBID} status "balancing_pool:"
	else
		bset status "balancing_pool:"
	fi

	# For everything ready-to-build...
	for pkg_dir in pool/unbalanced/*; do
		# May be empty due to racing with next_in_queue()
		case "${pkg_dir}" in
			"pool/unbalanced/*") break ;;
		esac
		pkgname=${pkg_dir##*/}
		hash_get "priority" "${pkgname}" dep_count || dep_count=0
		# This races with next_in_queue(), just ignore failure
		# to move it.
		rename "${pkg_dir}" \
		    "pool/${dep_count}/${pkgname}" \
		    2>/dev/null || :
	done
	# New files may have been added in unbalanced/ via clean.sh due to not
	# being locked. These will be picked up in the next run.

	rmdir ${lock}
}

append_make() {
	[ $# -ne 2 ] && eargs append_make src_makeconf dst_makeconf
	local src_makeconf=$1
	local dst_makeconf=$2

	if [ "${src_makeconf}" = "-" ]; then
		src_makeconf="${POUDRIERED}/make.conf"
	else
		src_makeconf="${POUDRIERED}/${src_makeconf}-make.conf"
	fi

	[ -f "${src_makeconf}" ] || return 0
	src_makeconf="$(realpath ${src_makeconf} 2>/dev/null)"
	# Only append if not already done (-z -p or -j match)
	grep -q "# ${src_makeconf} #" ${dst_makeconf} && return 0
	msg "Appending to make.conf: ${src_makeconf}"
	echo "#### ${src_makeconf} ####" >> ${dst_makeconf}
	cat "${src_makeconf}" >> ${dst_makeconf}
}

read_packages_from_params()
{
	if [ $# -eq 0 ]; then
		[ -n "${LISTPKGS}" -o ${ALL} -eq 1 ] ||
		    err 1 "No packages specified"
		if [ ${ALL} -eq 0 ]; then
			for listpkg_name in ${LISTPKGS}; do
				[ -f "${listpkg_name}" ] ||
				    err 1 "No such list of packages: ${listpkg_name}"
			done
		fi
	else
		[ ${ALL} -eq 0 ] ||
		    err 1 "command line arguments and -a cannot be used at the same time"
		[ -z "${LISTPKGS}" ] ||
		    err 1 "command line arguments and list of ports cannot be used at the same time"
		LISTPORTS="$@"
	fi
}

clean_restricted() {
	msg "Cleaning restricted packages"
	bset status "clean_restricted:"
	# Remount rw
	# mount_nullfs does not support mount -u
	umount ${UMOUNT_NONBUSY} ${MASTERMNT}/packages
	mount_packages
	injail /usr/bin/make -s -C ${PORTSDIR} -j ${PARALLEL_JOBS} \
	    RM="/bin/rm -fv" ECHO_MSG="true" clean-restricted
	# Remount ro
	umount ${UMOUNT_NONBUSY} ${MASTERMNT}/packages
	mount_packages -o ro
}

sign_pkg() {
	[ $# -eq 2 ] || eargs sign_pkg sigtype pkgfile
	local sigtype="$1"
	local pkgfile="$2"

	if [ "${sigtype}" = "fingerprint" ]; then
		rm -f "${pkgfile}.sig"
		sha256 -q "${pkgfile}" | ${SIGNING_COMMAND} > "${pkgfile}.sig"
	elif [ "${sigtype}" = "pubkey" ]; then
		rm -f "${pkgfile}.pubkeysig"
		echo -n $(sha256 -q "${pkgfile}") | \
		    openssl dgst -sha256 -sign "${PKG_REPO_SIGNING_KEY}" \
		    -binary -out "${pkgfile}.pubkeysig"
	fi
}

build_repo() {
	local origin

	msg "Creating pkg repository"
	bset status "pkgrepo:"
	ensure_pkg_installed force_extract || \
	    err 1 "Unable to extract pkg."
	if [ -r "${PKG_REPO_META_FILE:-/nonexistent}" ]; then
		PKG_META="-m /tmp/pkgmeta"
		PKG_META_MASTERMNT="-m ${MASTERMNT}/tmp/pkgmeta"
		install -m 0400 "${PKG_REPO_META_FILE}" \
		    ${MASTERMNT}/tmp/pkgmeta
	fi
	mkdir -p ${MASTERMNT}/tmp/packages
	if [ -n "${PKG_REPO_SIGNING_KEY}" ]; then
		install -m 0400 ${PKG_REPO_SIGNING_KEY} \
			${MASTERMNT}/tmp/repo.key
		injail ${PKG_BIN} repo -o /tmp/packages \
			${PKG_META} \
			/packages /tmp/repo.key
		rm -f ${MASTERMNT}/tmp/repo.key
	elif [ "${PKG_REPO_FROM_HOST:-no}" = "yes" ]; then
		# Sometimes building repo from host is needed if
		# using SSH with DNSSEC as older hosts don't support
		# it.
		${MASTERMNT}${PKG_BIN} repo \
		    -o ${MASTERMNT}/tmp/packages ${PKG_META_MASTERMNT} \
		    ${MASTERMNT}/packages \
		    ${SIGNING_COMMAND:+signing_command: ${SIGNING_COMMAND}}
	else
		JNETNAME="n" injail ${PKG_BIN} repo \
		    -o /tmp/packages ${PKG_META} /packages \
		    ${SIGNING_COMMAND:+signing_command: ${SIGNING_COMMAND}}
	fi
	cp ${MASTERMNT}/tmp/packages/* ${PACKAGES}/

	# Sign the ports-mgmt/pkg package for bootstrap
	if [ -e "${PACKAGES}/Latest/pkg.txz" ]; then
		if [ -n "${SIGNING_COMMAND}" ]; then
			sign_pkg fingerprint "${PACKAGES}/Latest/pkg.txz"
		elif [ -n "${PKG_REPO_SIGNING_KEY}" ]; then
			sign_pkg pubkey "${PACKAGES}/Latest/pkg.txz"
		fi
	fi
}

# Builtin-only functions
_BUILTIN_ONLY=""
for _var in ${_BUILTIN_ONLY}; do
	if ! [ "$(type ${_var} 2>/dev/null)" = \
		"${_var} is a shell builtin" ]; then
		eval "${_var}() { return 0; }"
	fi
done
if [ "$(type setproctitle 2>/dev/null)" = "setproctitle is a shell builtin" ]; then
	setproctitle() {
		PROC_TITLE="$@"
		command setproctitle "poudriere${MASTERNAME:+[${MASTERNAME}]}${MY_JOBID:+[${MY_JOBID}]}: $@"
	}
else
	setproctitle() { }
fi

RESOLV_CONF=""
STATUS=0 # out of jail #
# cd into / to avoid foot-shooting if running from deleted dirs or
# NFS dir which root has no access to.
SAVED_PWD="${PWD}"
cd /

. ${SCRIPTPREFIX}/include/colors.pre.sh
[ -z "${POUDRIERE_ETC}" ] &&
    POUDRIERE_ETC=$(realpath ${SCRIPTPREFIX}/../../etc)
# If this is a relative path, add in ${PWD} as a cd / is done.
[ "${POUDRIERE_ETC#/}" = "${POUDRIERE_ETC}" ] && \
    POUDRIERE_ETC="${SAVED_PWD}/${POUDRIERE_ETC}"
POUDRIERED=${POUDRIERE_ETC}/poudriere.d
if [ -r "${POUDRIERE_ETC}/poudriere.conf" ]; then
	. "${POUDRIERE_ETC}/poudriere.conf"
elif [ -r "${POUDRIERED}/poudriere.conf" ]; then
	. "${POUDRIERED}/poudriere.conf"
else
	err 1 "Unable to find a readable poudriere.conf in ${POUDRIERE_ETC} or ${POUDRIERED}"
fi
include_poudriere_confs "$@"

AWKPREFIX=${SCRIPTPREFIX}/awk
HTMLPREFIX=${SCRIPTPREFIX}/html
HOOKDIR=${POUDRIERED}/hooks

# If the zfs module is not loaded it means we can't have zfs
[ -z "${NO_ZFS}" ] && lsvfs zfs >/dev/null 2>&1 || NO_ZFS=yes
# Short circuit to prevent running zpool(1) and loading zfs.ko
[ -z "${NO_ZFS}" ] && [ -z "$(zpool list -H -o name 2>/dev/null)" ] && NO_ZFS=yes

[ -z "${NO_ZFS}" -a -z ${ZPOOL} ] && err 1 "ZPOOL variable is not set"
[ -z ${BASEFS} ] && err 1 "Please provide a BASEFS variable in your poudriere.conf"

trap sigpipe_handler SIGPIPE
trap sigint_handler SIGINT
trap sigterm_handler SIGTERM
trap exit_handler EXIT
enable_siginfo_handler() {
	was_a_bulk_run && trap siginfo_handler SIGINFO
	in_siginfo_handler=0
	return 0
}
enable_siginfo_handler

# Test if zpool exists
if [ -z "${NO_ZFS}" ]; then
	zpool list ${ZPOOL} >/dev/null 2>&1 || err 1 "No such zpool: ${ZPOOL}"
fi

: ${SVN_HOST="svn.freebsd.org"}
: ${GIT_BASEURL="github.com/freebsd/freebsd.git"}
: ${GIT_PORTSURL="github.com/freebsd/freebsd-ports.git"}
: ${FREEBSD_HOST="https://download.FreeBSD.org"}
if [ -z "${NO_ZFS}" ]; then
	: ${ZROOTFS="/poudriere"}
	case ${ZROOTFS} in
	[!/]*) err 1 "ZROOTFS shoud start with a /" ;;
	esac
fi

HOST_OSVERSION="$(sysctl -n kern.osreldate)"
if [ -z "${NO_ZFS}" -a -z "${ZFS_DEADLOCK_IGNORED}" ]; then
	[ ${HOST_OSVERSION} -gt 900000 -a \
	    ${HOST_OSVERSION} -le 901502 ] && err 1 \
	    "FreeBSD 9.1 ZFS is not safe. It is known to deadlock and cause system hang. Either upgrade the host or set ZFS_DEADLOCK_IGNORED=yes in poudriere.conf"
fi

: ${USE_TMPFS:=no}
[ -n "${MFSSIZE}" -a "${USE_TMPFS}" != "no" ] && err 1 "You can't use both tmpfs and mdmfs"

for val in ${USE_TMPFS}; do
	case ${val} in
	wrkdir) TMPFS_WRKDIR=1 ;;
	data) TMPFS_DATA=1 ;;
	all) TMPFS_ALL=1 ;;
	localbase) TMPFS_LOCALBASE=1 ;;
	yes)
		TMPFS_WRKDIR=1
		TMPFS_DATA=1
		;;
	no) ;;
	*) err 1 "Unknown value for USE_TMPFS can be a combination of wrkdir,data,all,yes,no,localbase" ;;
	esac
done

case ${TMPFS_WRKDIR}${TMPFS_DATA}${TMPFS_LOCALBASE}${TMPFS_ALL} in
1**1|*1*1|**11)
	TMPFS_WRKDIR=0
	TMPFS_DATA=0
	TMPFS_LOCALBASE=0
	;;
esac

POUDRIERE_DATA=`get_data_dir`
: ${WRKDIR_ARCHIVE_FORMAT="tbz"}
case "${WRKDIR_ARCHIVE_FORMAT}" in
	tar|tgz|tbz|txz);;
	*) err 1 "invalid format for WRKDIR_ARCHIVE_FORMAT: ${WRKDIR_ARCHIVE_FORMAT}" ;;
esac

#Converting portstree if any
if [ ! -d ${POUDRIERED}/ports ]; then
	mkdir -p ${POUDRIERED}/ports
	[ -z "${NO_ZFS}" ] && zfs list -t filesystem -H \
		-o ${NS}:type,${NS}:name,${NS}:method,mountpoint,name | \
		grep "^ports" | \
		while read t name method mnt fs; do
			msg "Converting the ${name} ports tree"
			pset ${name} method ${method}
			pset ${name} mnt ${mnt}
			pset ${name} fs ${fs}
			# Delete the old properties
			zfs inherit -r ${NS}:type ${fs}
			zfs inherit -r ${NS}:name ${fs}
			zfs inherit -r ${NS}:method ${fs}
		done
	if [ -f ${POUDRIERED}/portstrees ]; then
		while read name method mnt; do
			[ -z "${name###*}" ] && continue # Skip comments
			msg "Converting the ${name} ports tree"
			mkdir ${POUDRIERED}/ports/${name}
			echo ${method} > ${POUDRIERED}/ports/${name}/method
			echo ${mnt} > ${POUDRIERED}/ports/${name}/mnt
		done < ${POUDRIERED}/portstrees
		rm -f ${POUDRIERED}/portstrees
	fi
fi

#Converting jails if any
if [ ! -d ${POUDRIERED}/jails ]; then
	mkdir -p ${POUDRIERED}/jails
	[ -z "${NO_ZFS}" ] && zfs list -t filesystem -H \
		-o ${NS}:type,${NS}:name,${NS}:version,${NS}:arch,${NS}:method,mountpoint,name | \
		grep "^rootfs" | \
		while read t name version arch method mnt fs; do
			msg "Converting the ${name} jail"
			jset ${name} version ${version}
			jset ${name} arch ${arch}
			jset ${name} method ${method}
			jset ${name} mnt ${mnt}
			jset ${name} fs ${fs}
			# Delete the old properties
			zfs inherit -r ${NS}:type ${fs}
			zfs inherit -r ${NS}:name ${fs}
			zfs inherit -r ${NS}:method ${fs}
			zfs inherit -r ${NS}:version ${fs}
			zfs inherit -r ${NS}:arch ${fs}
			zfs inherit -r ${NS}:stats_built ${fs}
			zfs inherit -r ${NS}:stats_failed ${fs}
			zfs inherit -r ${NS}:stats_skipped ${fs}
			zfs inherit -r ${NS}:stats_ignored ${fs}
			zfs inherit -r ${NS}:stats_queued ${fs}
			zfs inherit -r ${NS}:status ${fs}
		done
fi

: ${LOIP6:=::1}
: ${LOIP4:=127.0.0.1}
case $IPS in
01)
	localipargs="ip6.addr=${LOIP6}"
	ipargs="ip6=inherit"
	;;
10)
	localipargs="ip4.addr=${LOIP4}"
	ipargs="ip4=inherit"
	;;
11)
	localipargs="ip4.addr=${LOIP4} ip6.addr=${LOIP6}"
	ipargs="ip4=inherit ip6=inherit"
	;;
esac

NCPU=$(sysctl -n hw.ncpu)

# Check if parallel umount will contend on the vnode free list lock
if sysctl -n vfs.mnt_free_list_batch >/dev/null 2>&1; then
	# Nah, parallel umount should be fine.
	UMOUNT_BATCHING=1
else
	UMOUNT_BATCHING=0
fi
# Determine if umount -n can be used.
if grep -q "#define[[:space:]]MNT_NONBUSY" /usr/include/sys/mount.h \
    2>/dev/null; then
	UMOUNT_NONBUSY="-n"
fi

case ${PARALLEL_JOBS} in
''|*[!0-9]*)
	PARALLEL_JOBS=${NCPU}
	;;
esac

case ${POOL_BUCKETS} in
''|*[!0-9]*)
	# 1 will auto determine proper size, 0 disables.
	POOL_BUCKETS=1
	;;
esac

if [ "${PRESERVE_TIMESTAMP:-no}" = "yes" ]; then
	SVN_PRESERVE_TIMESTAMP="--config-option config:miscellany:use-commit-times=yes"
fi

: ${WATCHDIR:=${POUDRIERE_DATA}/queue}
: ${PIDFILE:=${POUDRIERE_DATA}/daemon.pid}
: ${QUEUE_SOCKET:=/var/run/poudriered.sock}
: ${PORTBUILD_UID:=65532}
: ${PORTBUILD_GID:=${PORTBUILD_UID}}
: ${PORTBUILD_USER:=nobody}
: ${CCACHE_DIR_NON_ROOT_SAFE:=no}
if [ -n "${CCACHE_DIR}" ] && [ "${CCACHE_DIR_NON_ROOT_SAFE}" = "no" ]; then
	if [ "${BUILD_AS_NON_ROOT}" = "yes" ]; then
		msg_warn "BUILD_AS_NON_ROOT and CCACHE_DIR are potentially incompatible.  Disabling BUILD_AS_NON_ROOT"
		msg_warn "Either disable one or set CCACHE_DIR_NON_ROOT_SAFE=yes and chown -R CCACHE_DIR to the user ${PORTBUILD_USER} (uid: ${PORTBUILD_UID})"
	fi
	# Default off with CCACHE_DIR.
	: ${BUILD_AS_NON_ROOT:=no}
fi
# Default on otherwise.
: ${BUILD_AS_NON_ROOT:=yes}
: ${DISTFILES_CACHE:=/nonexistent}
: ${SVN_CMD:=$(which svn 2>/dev/null || which svnlite 2>/dev/null)}
: ${BINMISC:=/usr/sbin/binmiscctl}
# 24 hours for 1 command
: ${MAX_EXECUTION_TIME:=86400}
# 120 minutes with no log update
: ${NOHANG_TIME:=7200}
: ${PATCHED_FS_KERNEL:=no}
: ${ALL:=0}
: ${CLEAN:=0}
: ${CLEAN_LISTED:=0}
: ${JAIL_NEEDS_CLEAN:=0}
: ${VERBOSE:=0}
: ${QEMU_EMULATING:=0}
: ${PORTTESTING_FATAL:=yes}
: ${PORTTESTING_RECURSIVE:=0}
: ${PRIORITY_BOOST_VALUE:=99}
: ${RESTRICT_NETWORKING:=yes}
: ${TRIM_ORPHANED_BUILD_DEPS:=yes}
: ${USE_JEXECD:=no}
: ${USE_PROCFS:=yes}
: ${USE_FDESCFS:=yes}
: ${USE_PTSORT:=yes}
: ${MUTABLE_BASE:=yes}
: ${HTML_JSON_UPDATE_INTERVAL:=2}

# Be sure to update poudriere.conf to document the default when changing these
: ${MAX_EXECUTION_TIME:=86400}         # 24 hours for 1 command
: ${NOHANG_TIME:=7200}                 # 120 minutes with no log update
: ${TIMESTAMP_LOGS:=no}
: ${ATOMIC_PACKAGE_REPOSITORY:=yes}
: ${KEEP_OLD_PACKAGES:=no}
: ${KEEP_OLD_PACKAGES_COUNT:=5}
: ${COMMIT_PACKAGES_ON_FAILURE:=yes}
: ${SAVE_WRKDIR:=no}
: ${CHECK_CHANGED_DEPS:=yes}
: ${CHECK_CHANGED_OPTIONS:=verbose}
: ${NO_RESTRICTED:=no}
: ${USE_COLORS:=yes}
: ${ALLOW_MAKE_JOBS_PACKAGES=pkg ccache}

: ${POUDRIERE_TMPDIR:=$(command mktemp -dt poudriere)}
: ${SHASH_VAR_PATH_DEFAULT:=${POUDRIERE_TMPDIR}}
: ${SHASH_VAR_PATH:=${SHASH_VAR_PATH_DEFAULT}}
: ${SHASH_VAR_PREFIX:=sh-}

: ${USE_CACHED:=no}

: ${BUILDNAME_FORMAT:="%Y-%m-%d_%Hh%Mm%Ss"}
: ${BUILDNAME:=$(date +${BUILDNAME_FORMAT})}

: ${HTML_TYPE:=inline}

if [ -n "${MAX_MEMORY}" ]; then
	MAX_MEMORY_BYTES="$((${MAX_MEMORY} * 1024 * 1024 * 1024))"
fi
: ${MAX_FILES:=1024}

TIME_START=$(clock -monotonic)
EPOCH_START=$(clock -epoch)

[ -d ${WATCHDIR} ] || mkdir -p ${WATCHDIR}

. ${SCRIPTPREFIX}/include/util.sh
. ${SCRIPTPREFIX}/include/colors.sh
. ${SCRIPTPREFIX}/include/display.sh
. ${SCRIPTPREFIX}/include/html.sh
. ${SCRIPTPREFIX}/include/parallel.sh
. ${SCRIPTPREFIX}/include/hash.sh
. ${SCRIPTPREFIX}/include/shared_hash.sh
. ${SCRIPTPREFIX}/include/cache.sh
. ${SCRIPTPREFIX}/include/fs.sh

if [ -e /nonexistent ]; then
	err 1 "You may not have a /nonexistent.  Please remove it."
fi
