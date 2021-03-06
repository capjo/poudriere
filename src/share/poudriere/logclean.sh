#!/bin/sh
# 
# Copyright (c) 2014-2017 Bryan Drewery <bdrewery@FreeBSD.org>
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

usage() {
	cat <<EOF
poudriere logclean [options] days

Parameters:
    days        -- How many days old of logfiles to keep

Options:
    -j jail     -- Which jail to use for log directories
    -p tree     -- Specify which ports tree to use for log directories
                   (Defaults to the 'default' tree)
    -n          -- Do not actually remove anything, just show what would be
                   removed
    -v          -- Be verbose; show more information. Use twice to enable
                   debug output
    -y          -- Assume yes when deleting and do not prompt for confirmation
    -z set      -- Specify which SET to use for log directories
EOF
	exit 1
}

PTNAME=
SETNAME=
DRY_RUN=0
ALL=1

. ${SCRIPTPREFIX}/common.sh

while getopts "j:p:nvyz:" FLAG; do
	case "${FLAG}" in
		j)
			JAILNAME=${OPTARG}
			;;
		n)
			DRY_RUN=1
			;;
		p)
			PTNAME=${OPTARG}
			;;
		v)
			VERBOSE=$((${VERBOSE} + 1))
			;;
		y)
			answer=yes
			;;
		z)
			[ -n "${OPTARG}" ] || err 1 "Empty set name"
			SETNAME="${OPTARG}"
			;;
		*)
			usage
			;;
	esac
done

shift $((OPTIND-1))
post_getopts

if [ $# -eq 0 ]; then
	usage
fi
DAYS=$1

POUDRIERE_BUILD_TYPE="bulk"
_log_path_top log_top

CLEANUP_HOOK=logclean_cleanup
logclean_cleanup() {
	rm -f ${OLDLOGS} 2>/dev/null
}
OLDLOGS=$(mktemp -t poudriere_logclean)

cd ${log_top}

# Logfiles in latest-per-pkg should have 3 links total.
#  1 = itself
#  2 = jail-specific latest-per-pkg
#  3 = build-specific log
# Find logs that are missing their jail-specific or build-specific links.
find_broken_latest_per_pkg_links() {
	[ "${PWD}" = "${log_top}" ] || \
	    err 1 "find_broken_latest_per_pkg_links requires PWD=${log_top}"

	log_links=3
	find latest-per-pkg -type f ! -links ${log_links}
	# Each MASTERNAME/latest-per-pkg
	find . -mindepth 2 -maxdepth 2 -name latest-per-pkg -print0 | \
	    xargs -0 -J {} find {} -type f ! -links ${log_links} | \
	    sed -e 's,^\./,,'
}

# Very old style symlinks.  Find broken links.
delete_broken_latest_per_pkg_old_symlinks() {
	[ "${PWD}" = "${log_top}" ] || \
	    err 1 "find_broken_latest_per_pkg_old_symlinks requires PWD=${log_top}"

	find -L latest-per-pkg -type l -exec rm -f {} +
	# Each MASTERNAME/latest-per-pkg
	find . -mindepth 2 -maxdepth 2 -name latest-per-pkg -print0 | \
	    xargs -0 -J {} find -L {} -type l -exec rm -f {} +
}

# Find now-empty latest-per-pkg directories.  This will take 3 runs
# to actually clear out a package.
delete_empty_latest_per_pkg() {
	[ "${PWD}" = "${log_top}" ] || \
	    err 1 "find_empty_latest_per_pkg requires PWD=${log_top}"

	find latest-per-pkg -mindepth 1 -type d -empty -delete
}

echo_logdir() {
	printf "${log}\000"
}

reason="builds older than ${DAYS} days in ${log_top} (filtered)"
msg_n "Looking for ${reason}..."
{
	# Find build directories older than DAYS
	BUILDNAME_GLOB="*" SHOW_FINISHED=1 \
	    for_each_build echo_logdir | \
	    xargs -0 -J {} \
	    find {} -mindepth 0 -maxdepth 0 -Btime +${DAYS}d
} > "${OLDLOGS}"
echo " done"
# Confirm these logs are safe to delete.
ret=0
do_confirm_delete "${OLDLOGS}" \
    "${reason}" \
    "${answer}" "${DRY_RUN}" || ret=$?
# ret = 2 means no files were deleted, but let's still
# cleanup other broken/stale files and links.
logs_deleted=0
if [ ${ret} -eq 1 ]; then
	logs_deleted=1
fi

# Save which builds were modified for later html_json rewriting
DELETED_BUILDS="$(cat "${OLDLOGS}" | cut -d / -f 1 | sort -u)"

# Once that is done, we have a latest-per-pkg links to cleanup.
reason="detached latest-per-pkg logfiles in ${log_top} (no filter)"
msg_n "Looking for ${reason}..."
{
	find_broken_latest_per_pkg_links
} > "${OLDLOGS}"
echo " done"
# Confirm latest-per-pkg links are OK to cleanup
ret=0
do_confirm_delete "${OLDLOGS}" \
    "${reason}" \
    "${answer}" "${DRY_RUN}" || ret=$?

msg_n "Removing broken legacy latest-per-pkg symlinks (no filter)..."
# Now we can cleanup dead links and empty directories.  Empty
# directories will take 2 passes to complete.
delete_broken_latest_per_pkg_old_symlinks
echo " done"
msg_n "Removing empty latest-per-pkg directories (no filter)..."
delete_empty_latest_per_pkg
echo " done"

if [ ${logs_deleted} -eq 1 ]; then
	msg_n "Removing empty build log directories..."
	echo "${DELETED_BUILDS}" | sed -e 's,$,/latest-per-pkg,' | \
	    tr '\n' '\000' | \
	    xargs -0 -J % find % -mindepth 0 -maxdepth 0 -empty | \
	    sed -e 's,$,/..,' | xargs realpath | tr '\n' '\000' | \
	    xargs -0 rm -rf
	echo " done"

	msg "Rebuilding HTML JSON files..."
	for MASTERNAME in ${DELETED_BUILDS}; do
		# Was this build eliminated?
		[ -d "${MASTERNAME}" ] || continue
		msg_n "Rebuilding HTML JSON for: ${MASTERNAME}..."
		_log_path_jail log_path_jail
		build_jail_json || :
		echo " done"
	done
	msg_n "Rebuilding HTML JSON for top-level..."
	log_path_top="${log_top}"
	build_top_json || :
	echo " done"
fi

exit 0
