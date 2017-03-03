#!/bin/sh -eu
#
#  Copyright (c) 2017 Sebastien Marie <semarie@online.fr>
# 
#  Permission to use, copy, modify, and distribute this software for any
#  purpose with or without fee is hereby granted, provided that the above
#  copyright notice and this permission notice appear in all copies.
# 
#  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
#  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
#  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
#  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
#  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
#  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
#  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
PATH=/bin:/usr/bin:/usr/sbin:/usr/local/bin

build_rust="$0"

if [[ $# -eq 0 ]]; then
	echo "usage: $0 target command" >&2
	"${build_rust}" help
	exit 1
fi

[[ -n ${DEBUG:-} ]] && set -x

# load default variables
[[ -r "${HOME}/.build_rust.conf" ]] \
	&& . "${HOME}/.build_rust.conf"

# default variables
distfiles_rustc_base="${distfiles_rustc_base:-https://static.rust-lang.org/dist}"
distfiles_cargo_base="${distfiles_cargo_base:-https://github.com/rust-lang/cargo/archive}"
build_dir="${build_dir:-build_dir}"
install_dir="${install_dir:-install_dir}"
SUDO="${SUDO:-}"
ccache="${ccache:-yes}"
llvm_config="${llvm_config:-}"
CFLAGS="${CFLAGS:--O2 -pipe}"

def_MAKE_JOBS=$(sysctl -n hw.ncpu)
MAKE_JOBS=${MAKE_JOBS:-${def_MAKE_JOBS}}

# practical variables (based on user-defined ones)
dist_dir="${install_dir}/dist"
crates_dir="${install_dir}/crates"
rustc_dir="${build_dir}/rustc"
cargo_dir="${build_dir}/cargo"

# use canonicalize version
mkdir -p "${install_dir}" "${build_dir}"
build_dir=$(readlink -fn "${build_dir}")
install_dir=$(readlink -fn "${install_dir}")
dist_dir=$(readlink -fn "${dist_dir}")
rustc_dir=$(readlink -fn "${rustc_dir}")
cargo_dir=$(readlink -fn "${cargo_dir}")
crates_dir=$(readlink -fn "${crates_dir}")

# cargo configuration
CARGO_HOME="${crates_dir}"
LIBGIT2_SYS_USE_PKG_CONFIG=1
VERBOSE=1
export CARGO_HOME LIBGIT2_SYS_USE_PKG_CONFIG VERBOSE CFLAGS

case $(arch -s) in
i386)
	triple_arch='i686-unknown-openbsd'
	;;
amd64)
	triple_arch='x86_64-unknown-openbsd'
	;;
*)
	echo "error: unsupported arch" >&2
	exit 1
	;;
esac

log() {
	echo "`date`: ${@}"
}

refetch() {
	local url="$1"
	local file="$2"

	# get ETag of remote file
	local new_etag=$(curl -s -L -I "${url}" | sed -ne 's/[Ee][Tt]ag: //p')

	# refetch only if ETag changed
	if [[ ! -e "${file}" || \
		-z "${new_etag}" \
		! -e "${file}.etag" || \
		$(cat "${file}.etag") != "${new_etag}" \
		]]; then

		curl -L -o "${file}" "${url}"
	fi

	# save the new ETag
	echo "${new_etag}" > "${file}.etag"
}

# get target and check it
target="$1"
shift

case "${target}" in
beta|nightly)
	# print timestamp
	[[ -z "${_recursive:-}" ]] && log "target: ${target} - ${triple_arch}"
	_recursive=1
	export _recursive
	;;
help)
	echo "available commands:"
	sed -ne 's/^\([a-z].*\))	*# \(.*\)$/ - \1:	\2/p' <$0
	exit 0
	;;
init)
	;;
*)
	echo "error: invalid target" >&2
	exit 1
esac

# source dir
rustc_xdir="${rustc_dir}/rust-src-${target}/rust-src/lib/rustlib/src/rust"
cargo_xdir="${cargo_dir}/cargo-${target}"

# get command
if [[ $# -eq 0 ]]; then
	# build the target
	command="${target}"
else
	command="$1"
	shift
fi

case "${command}" in
init)	# install some required packages (using pkg_add)
	if [[ -n ${llvm_config} ]]; then
		_llvm='llvm'
	else
		_llvm='cmake ninja'
	fi

	if [[ ${ccache} != "yes" ]]; then
		_ccache=''
	else
		_ccache='ccache'
	fi

	exec ${SUDO} pkg_add -a 'python%2.7' 'gmake' 'g++%4.9' 'git' \
		'curl' \
		${_ccache} \
		${_llvm}
	;;
fetch)	# fetch latest rust version
	log "fetching ${distfiles_rustc_base}/rust-src-${target}.tar.gz"
	mkdir -p -- "${dist_dir}"
	refetch "${distfiles_rustc_base}/rust-src-${target}.tar.gz"\
		"${dist_dir}/rust-src-${target}.tar.gz" \
	;;
extract)	# extract rust version from dist_dir to rustc_dir
	"${build_rust}" "${target}" fetch

	if [[ -d "${rustc_dir}/rust-src-${target}" ]]; then
		log "removing ${rustc_dir}/rust-src-${target}"
		rm -rf -- "${rustc_dir}/rust-src-${target}"
	fi
	mkdir -p -- "${rustc_dir}"

	log "extracting rust-src-${target}.tar.gz"
	exec tar zxf "${dist_dir}/rust-src-${target}.tar.gz" -C "${rustc_dir}"
	;;
patch)	# apply local patches
	[[ ! -d "${rustc_xdir}" ]] && \
		"${build_rust}" "${target}" extract

	log "patching ${target}"

	[[ ! -d "patches-${target}" ]] && exit 0

	cat "patches-${target}"/*.patch \
		| patch -d "${rustc_xdir}" -p0 -E
	;;
rustbuild)	# rustbuild wrapper
	[[ ! -r "${rustc_xdir}/.configure-${target}" ]] \
		&& "${build_rust}" "${target}" configure

	log "starting rustbuild ${@}"
	ulimit -c 0
	ulimit -d `ulimit -dH`
	cd "${rustc_dir}" && exec env \
		PATH="${build_dir}/bin:${PATH}" \
		"python2.7" "${rustc_xdir}/src/bootstrap/bootstrap.py" \
			"$@"
	;;
clean)	# run rustbuild clean (do not remove llvm)
	[[ ! -d "${rustc_dir}/build" \
		|| ! -r "${rustc_xdir}/.configure-${target}" \
		]] && exit 0

	exec "${build_rust}" "${target}" rustbuild clean
	;;
clean-all)	# remove build_dir
	log "cleaning ${build_dir}"
	exec rm -rf -- "${build_dir}"
	;;
pre-configure)
	# create bin directory wrapper
	mkdir -p "${build_dir}/bin"
	for _p in gcc g++; do
		if [[ "${ccache}" != "yes" ]]; then
			ln -fs "/usr/local/bin/e${_p}" "${build_dir}/bin/${_p}"
		else	
			rm -f "${build_dir}/bin/${_p}" || true
			echo '#!/bin/sh' >"${build_dir}/bin/${_p}"
			echo "exec ccache /usr/local/bin/e${_p} \"\${@}\"" \
				>>"${build_dir}/bin/${_p}"
			chmod 755 "${build_dir}/bin/${_p}"
		fi
	done
	ln -fs "gcc" "${build_dir}/bin/cc"
	ln -fs "g++" "${build_dir}/bin/c++"
	;;
configure)	# configure target
	"${build_rust}" "${target}" pre-configure

	# configure target dependent stuff
	case "${target}" in
	beta)
		dep_dir="/usr/local"

		# install rustc-stable
		if [[ ! -x "${dep_dir}/bin/rustc" ]]; then
			log "installing rustc-stable (from ports)"
			${SUDO} pkg_add -a rust
		fi
		;;
	nightly)
		dep_dir="${install_dir}/beta"

		# install rustc-beta
		if [[ ! -x "${dep_dir}/bin/rustc" ]] ; then
			echo "warn: missing rustc-beta" >&2
			"${build_rust}" beta
		fi
		;;
	esac

	# require cargo-${target}
	if [[ ! -x "${install_dir}/${target}/bin/cargo" ]] ; then
		echo "warn: missing cargo-${target}" >&2
		"${build_rust}" "${target}" cargo-install
	fi

	# require source tree
	[[ ! -r "${rustc_xdir}/src/bootstrap/bootstrap.py" ]] \
		&& "${build_rust}" "${target}" patch

	# llvm stuff
	if [[ -n ${llvm_config} ]]; then
		_llvm='llvm-config'
	else
		_llvm='#llvm-config'
	fi

	# generate config file
	mkdir -p "${rustc_dir}"
	cat >"${rustc_dir}/config.toml" <<EOF
[build]
rustc = "${dep_dir}/bin/rustc"
cargo = "${install_dir}/${target}/bin/cargo"
prefix = "${install_dir}/${target}"
docs = false
vendor = true

[dist]
src-tarball = false

[rust]
channel = "${target}"
codegen-tests = false

[target.${triple_arch}]
${_llvm} = "${llvm_config}"

[llvm]
static-libstdcpp = false
ninja = true
EOF
	exec touch "${rustc_xdir}/.configure-${target}"
	;;
build)	# invoke rustbuild for making dist files

	# make build
	"${build_rust}" "${target}" rustbuild dist -v --jobs=${MAKE_JOBS}

	# copy distfiles
	log "copying ${target} distfiles to ${dist_dir}"
	mkdir -p "${dist_dir}"
	for _c in rustc rust-std; do
		_f="${rustc_dir}/build/dist/${_c}-${target}-${triple_arch}.tar.gz"
		ln -f "${_f}" "${dist_dir}" \
			|| cp -f "${_f}" "${dist_dir}"
	done
	;;
install)	# install sets

	# install rustc and rust-std sets
	for _c in rustc rust-std; do
		log "installing ${_c}-${target}"

		if [[ ! -r "${dist_dir}/${_c}-${target}-${triple_arch}.tar.gz" ]]; then
			echo "error: missing ${_c}-${target}-${triple_arch}.tar.gz" >&2
			exit 1
		fi

		tmpdir=`mktemp -d -p "${install_dir}" "rust-${target}.XXXXXX"` \
			|| exit 1
		tar zxf "${dist_dir}/${_c}-${target}-${triple_arch}.tar.gz" \
			-C "${tmpdir}"
		"${tmpdir}/${_c}-${target}-${triple_arch}/install.sh" \
			--prefix="${install_dir}/${target}"
		rm -rf -- "${tmpdir}"
	done

	# replace rustc by a wrapper (for LD_LIBRARY_PATH)
	mv "${install_dir}/${target}/bin/rustc" \
		"${install_dir}/${target}/bin/rustc.bin"
	echo '#!/bin/sh' \
		>"${install_dir}/${target}/bin/rustc"
	echo "LD_LIBRARY_PATH='${install_dir}/${target}/lib' exec '${install_dir}/${target}/bin/rustc.bin' \"\$@\"" \
		>>"${install_dir}/${target}/bin/rustc"
	chmod 755 "${install_dir}/${target}/bin/rustc"

	# XXX copy system lib ?
	;;
beta|nightly)	# prepare a release
	mkdir -p "${install_dir}/${target}"
	(
	"${build_rust}" "${target}" clean
	"${build_rust}" "${target}" extract
	"${build_rust}" "${target}" patch
	"${build_rust}" "${target}" cargo
	"${build_rust}" "${target}" configure
	"${build_rust}" "${target}" build
	"${build_rust}" "${target}" install
	) 2>&1 | tee "${install_dir}/${target}/build.log"
	;;
cargo-fetch)
	# get cargo version required by rustc
	[[ ! -r "${rustc_xdir}/src/stage0.txt" ]] \
		&& "${build_rust}" "${target}" patch
	commitid=$(sed -ne 's/^cargo: *//p' "${rustc_xdir}/src/stage0.txt")

	log "fetching cargo-${target} ${commitid}"
	refetch "${distfiles_cargo_base}/${commitid}.tar.gz" \
		"${dist_dir}/cargo-${target}.tar.gz"
	;;
cargo-extract)
	"${build_rust}" "${target}" cargo-fetch

	# get cargo version required by rustc
	[[ ! -r "${rustc_xdir}/src/stage0.txt" ]] \
		&& "${build_rust}" "${target}" patch
	commitid=$(sed -ne 's/^cargo: *//p' "${rustc_xdir}/src/stage0.txt")

	if [[ -d "${cargo_dir}" ]]; then
		log "removing ${cargo_dir}"
		rm -rf -- "${cargo_dir}"
	fi
	mkdir -p -- "${cargo_dir}"

	log "extracting cargo-${target} ${commitid}"
	tar zxf "${dist_dir}/cargo-${target}.tar.gz" \
		-C "${cargo_dir}"

	exec ln -fs "cargo-${commitid}" "${cargo_dir}/cargo-${target}"
	;;
cargo-patch)
	[[ ! -e "${cargo_xdir}" ]] \
		&& "${build_rust}" "${target}" cargo-extract

	# >= libc-0.2.19 : support of OpenBSD i386
	# >= openssl-0.9.4 : support of LibreSSL

	log "patching cargo-${target}"
	case "${target}" in
	beta)
		cd "${cargo_xdir}" && exec /usr/local/bin/cargo update \
			-p libc \
			-p openssl -p openssl-sys
		;;
	nightly)
		cd "${cargo_xdir}" && exec "${install_dir}/beta/bin/cargo" update \
			-p libc \
			-p openssl -p openssl-sys
	esac
	;;
cargo-configure)
	"${build_rust}" "${target}" pre-configure

	case "${target}" in
	beta)
		dep_dir="/usr/local"
		ptarget="stable"

		# install rustc-stable
		if [[ ! -x "${dep_dir}/bin/rustc" ]]; then
			log "installing rustc-stable (from ports)"
			${SUDO} pkg_add -a rust
		fi

		# install cargo-stable
		if [[ ! -x "${dep_dir}/bin/cargo" ]]; then
			log "installing cargo-stable (from ports)"
			${SUDO} pkg_add -a cargo
		fi
		;;
	nightly)
		dep_dir="${install_dir}/beta"
		ptarget="beta"
		;;
	esac

	if [[ ! -x "${dep_dir}/bin/rustc" ]]; then
		echo "warn: missing rustc-${ptarget}" >&2
		"${build_rust}" "${ptarget}"
	fi

	[[ ! -e "${cargo_xdir}" ]] \
		&& "${build_rust}" "${target}" cargo-patch

	log "configuring cargo-${target}"
	cd "${cargo_xdir}" && exec env \
		PATH="${build_dir}/bin:${dep_dir}/bin:${PATH}" \
		./configure \
			--prefix="${install_dir}/${target}" \
			--rustc="${dep_dir}/bin/rustc"
	;;
cargo-build)
	[[ ! -r "${cargo_xdir}/Makefile" ]] \
		&& "${build_rust}" "${target}" cargo-configure

	log "building cargo-${target}"
	cd "${cargo_xdir}" && exec gmake "$@"
	;;
cargo-install)
	[[ ! -x "${cargo_xdir}/target/${triple_arch}/release/cargo" ]] \
		&& "${build_rust}" "${target}" cargo-build

	log "installing cargo-${target}"
	mkdir -p -- "${install_dir}/${target}/bin"
	exec cp "${cargo_xdir}/target/${triple_arch}/release/cargo" \
		"${install_dir}/${target}/bin/cargo"
	;;
cargo)	# install cargo for the target, if not already installed
	# fetch cargo
	"${build_rust}" "${target}" cargo-fetch

	# check cargo binary existence and compare date with downloaded archive
	[[ -x "${install_dir}/${target}/bin/cargo" && \
		"${install_dir}/${target}/bin/cargo" \
			-nt "${dist_dir}/cargo-${target}.tar.gz" \
		]] \
		&& exit 0

	"${build_rust}" "${target}" cargo-install
	;;
run-rustc)
	if [[ ! -x "${install_dir}/${target}/bin/rustc" ]]; then
		echo "error: missing rustc-${target}" >&2
		exit 1
	fi
	exec env PATH="${install_dir}/${target}/bin:${PATH}" \
		"${install_dir}/${target}/bin/rustc" "${@}"
	;;
run-cargo)
	if [[ ! -x "${install_dir}/${target}/bin/cargo" ]]; then
		echo "error: missing cargo-${target}" >&2
		exit 1
	fi
	exec env PATH="${install_dir}/${target}/bin:${PATH}" \
		RUSTC="${install_dir}/${target}/bin/rustc" \
		"${install_dir}/${target}/bin/cargo" "${@}"
	;;
*)
	echo "error: unknown command: see $0 help"
	exit 1
	;;
esac
