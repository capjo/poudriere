#! /bin/sh

. common.sh
. ${SCRIPTPREFIX}/common.sh
PORTSDIR=${THISDIR}/ports
export PORTSDIR

port_var_fetch "devel/port_var_fetch1" \
    PKGNAME pkgname
assert "py34-sqlrelay-1.0.0_2" "${pkgname}" "PKGNAME"

# Try a lookup on a missing variable and ensure the value is cleared
blah="notcleared"
port_var_fetch "devel/port_var_fetch1" \
    BLAH blah
assert "" "${blah}" "blah variable not cleared on missing result"

pkgname=
port_var_fetch "devel/port_var_fetch1" \
    PKGNAME pkgname
assert "py34-sqlrelay-1.0.0_2" "${pkgname}" "PKGNAME"

port_var_fetch "devel/port_var_fetch1" \
	FOO='BLAH BLAH ${PKGNAME}' \
	PKGNAME pkgname \
	FOO foo \
	BLAH='blah' \
	IGNORE ignore \
	_PDEPS='${PKG_DEPENDS} ${EXTRACT_DEPENDS} ${PATCH_DEPENDS} ${FETCH_DEPENDS} ${BUILD_DEPENDS} ${LIB_DEPENDS} ${RUN_DEPENDS}' \
	_PDEPS pdeps \
	_UNKNOWN unknown \
	'${_PDEPS:C,([^:]*):([^:]*):?.*,\2,:C,^${PORTSDIR}/,,:O:u}' \
	pkg_deps
assert 0 $? "port_var_fetch should succeed"

assert "py34-sqlrelay-1.0.0_2" "${pkgname}" "PKGNAME"
assert "BLAH BLAH py34-sqlrelay-1.0.0_2" "${foo}" "FOO should have been overridden"
assert "test ignore 1 2 3" "${ignore}" "IGNORE"
assert "/usr/local/sbin/pkg:ports-mgmt/pkg /nonexistent:databases/sqlrelay:patch perl5>=5.20<5.21:lang/perl5.20  gmake:devel/gmake /usr/local/bin/python3.4:${PORTSDIR}/lang/python34 perl5>=5.20<5.21:lang/perl5.20 /usr/local/bin/ccache:devel/ccache libsqlrclient.so:${PORTSDIR}/databases/sqlrelay /usr/local/bin/python3.4:lang/python34" \
    "${pdeps}" "_PDEPS"
assert "" "${unknown}" "_UNKNOWN"
assert "databases/sqlrelay devel/ccache devel/gmake lang/perl5.20 lang/python34 ports-mgmt/pkg" \
    "${pkg_deps}" "PKG_DEPS eval"

pkgname=
port_var_fetch "foo" \
    PKGNAME pkgname 2>/dev/null
assert 1 $? "port_var_fetch invalid port should fail"
assert "" "${pkgname}" "PKGNAME shouldn't have gotten a value in a failed lookup"

pkgname=
port_var_fetch "devel/port_var_fetch1" \
    FAIL=1 \
    PKGNAME pkgname 2>/dev/null
assert 1 $? "port_var_fetch with FAIL set should fail"
assert "" "${pkgname}" "PKGNAME shouldn't have gotten a value in a failed lookup"

# Check for a syntax error failure
pkgname=
port_var_fetch "devel/port_var_fetch_syntax_error" \
    PKGNAME pkgname 2>/dev/null
assert 1 $? "port_var_fetch should detect make syntax error failure"
assert "" "${pkgname}" "PKGNAME shouldn't have gotten a value in a failed lookup"

# Lookup multiple vars to ensure the make errors to stdout don't cause confusion
port_var_fetch "devel/port_var_fetch_syntax_error" \
    PKG_DEPENDS pkg_depends \
    BUILD_DEPENDS build_depends \
    FETCH_DEPENDS fetch_depends \
    PKGNAME pkgname 2>/dev/null
assert 1 $? "port_var_fetch should detect make syntax error failure"
assert "" "${pkg_depends}" "PKG_DEPENDS shouldn't have gotten a value in a failed lookup"
assert "" "${pkg_depends}" "BUILD_DEPENDS shouldn't have gotten a value in a failed lookup"
assert "" "${build_depends}" "BUILD_DEPENDS shouldn't have gotten a value in a failed lookup"
assert "" "${fetch_depends}" "FETCH_DEPENDS shouldn't have gotten a value in a failed lookup"
assert "" "${pkgname}" "PKGNAME shouldn't have gotten a value in a failed lookup"

# Lookup 1 value with multiple errors returned
port_var_fetch "devel/port_var_fetch_syntax_error" \
    PKGNAME pkgname 2>/dev/null
assert 1 $? "port_var_fetch should detect make syntax error with 1 -V"
assert "" "${pkgname}" "PKGNAME shouldn't have gotten a value in a failed lookup"
