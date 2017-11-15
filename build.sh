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
build_dir="${build_dir:-build_dir}"
install_dir="${install_dir:-install_dir}"
SUDO="${SUDO:-}"
ccache="${ccache:-yes}"
llvm_config="${llvm_config:-/usr/local/bin/llvm-config}"
CFLAGS="${CFLAGS:--O2 -pipe}"

def_MAKE_JOBS=$(sysctl -n hw.ncpu)
MAKE_JOBS=${MAKE_JOBS:-${def_MAKE_JOBS}}

# practical variables (based on user-defined ones)
dist_dir="${install_dir}/dist"
crates_dir="${install_dir}/crates"
rustc_dir="${build_dir}/rustc"

# use canonicalize version
mkdir -p "${install_dir}" "${build_dir}"
build_dir=$(readlink -fn "${build_dir}")
install_dir=$(readlink -fn "${install_dir}")
dist_dir=$(readlink -fn "${dist_dir}")
rustc_dir=$(readlink -fn "${rustc_dir}")
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
	local message="$1"
	local url="$2"
	local file="$3"

	# get ETag of remote file
	local new_etag=$(curl -s -L -I "${url}" | sed -ne 's/[Ee][Tt]ag: //p')

	# refetch only if ETag changed
	if [[ ! -e "${file}" || \
		-z "${new_etag}" || \
		! -e "${file}.etag" || \
		$(cat "${file}.etag") != "${new_etag}" \
		]]; then

		log "fetching (cache miss): ${message}"
		curl -L -o "${file}" "${url}"
	else
		log "fetching (cache hit): ${message}"
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
rustc_xdir="${rustc_dir}/rustc-${target}-src"

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
	if [[ ${llvm_config} != "no" ]]; then
		_llvm='llvm'
	else
		_llvm='ninja'
	fi

	if [[ ${ccache} != "yes" ]]; then
		_ccache=''
	else
		_ccache='ccache'
	fi

	exec ${SUDO} pkg_add -a 'python%2.7' 'gmake' 'g++%4.9' 'git' \
		'curl' 'cmake' 'bash' \
		${_ccache} \
		${_llvm}
	;;
fetch)	# fetch latest rust version
	mkdir -p -- "${dist_dir}"
	refetch "rustc-${target}-src.tar.gz" \
		"${distfiles_rustc_base}/rustc-${target}-src.tar.gz" \
		"${dist_dir}/rustc-${target}-src.tar.gz" \
	;;
extract)	# extract rust version from dist_dir to rustc_dir
	"${build_rust}" "${target}" fetch

	if [[ -d "${rustc_dir}/rustc-${target}-src" ]]; then
		log "removing ${rustc_dir}/rustc-${target}-src"
		rm -rf -- "${rustc_dir}/rustc-${target}-src"
	fi
	mkdir -p -- "${rustc_dir}"

	log "extracting rustc-${target}-src.tar.gz"
	exec tar zxf "${dist_dir}/rustc-${target}-src.tar.gz" -C "${rustc_dir}"
	;;
patch)	# apply local patches
	[[ ! -d "${rustc_xdir}" ]] && \
		"${build_rust}" "${target}" extract

	log "patching ${target}"

	## bootstrap: pass optimization flags: https://github.com/rust-lang/rust/issues/39900
	echo 'patching: bootstrap: pass optimization flags'
	sed -ie 's/.*|s| !s.starts_with("-O") && !s.starts_with("\/O").*//' "${rustc_xdir}/src/bootstrap/lib.rs"

	## openssl-sys: libressl in -current isn't explicitly supported
	_libressl_lasted=$(sed -ne '/RUST_LIBRESSL_[0-9]/{p;q;}' "${rustc_xdir}/src/vendor/openssl-sys/build.rs")
	echo "patching: openssl-sys: libressl in -current isn't explicitly supported: using ${_libressl_lasted}"
	sed -ie "s/^RUST_LIBRESSL_NEW$/${_libressl_lasted}/" "${rustc_xdir}/src/vendor/openssl-sys/build.rs"
	sed -ie 's/"files":{[^}]*}/"files":{}/' "${rustc_xdir}/src/vendor/openssl-sys/.cargo-checksum.json"

	## filetime: don't try to use set_file_times_u()
	if grep -q '^1\.22\.' "${rustc_xdir}/version"; then
		echo "patching: filetime: don't try to use set_file_times_u()"
		sed -ie 's/android/openbsd/g' "${rustc_xdir}/src/vendor/filetime/src/unix.rs"
		sed -ie 's/"files":{[^}]*}/"files":{}/' "${rustc_xdir}/src/vendor/filetime/.cargo-checksum.json"
	fi

	exit 0
	;;
rustbuild)	# rustbuild wrapper
	[[ ! -r "${rustc_xdir}/.configure-${target}" ]] \
		&& "${build_rust}" "${target}" configure

	log "starting rustbuild ${@}"
	ulimit -c 0
	ulimit -d `ulimit -dH`
	cd "${rustc_dir}" && exec env \
		PATH="${build_dir}/bin:${PATH}" \
		"python2.7" "${rustc_xdir}/x.py" "$@"
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

		# install rustc-beta (will rebuild only if needed)
		"${build_rust}" beta
		;;
	esac

	# require source tree
	[[ ! -r "${rustc_xdir}/x.py" ]] \
		&& "${build_rust}" "${target}" patch

	# print information on current build
	log "info: building: $(cat ${rustc_xdir}/version)"
	log "info: rustc -vV"
	"${dep_dir}/bin/rustc" -vV
	log "info: cargo -vV"
	"${dep_dir}/bin/cargo" -vV

	# llvm stuff
	if [[ ${llvm_config} != "no" ]]; then
		_llvm='llvm-config'
	else
		_llvm='#llvm-config'
	fi

	# generate config file
	mkdir -p "${rustc_dir}"
	cat >"${rustc_dir}/config.toml" <<EOF
[build]
rustc = "${dep_dir}/bin/rustc"
cargo = "${dep_dir}/bin/cargo"
python = "/usr/local/bin/python2.7"
#docs = false
vendor = true
extended = true
verbose = 2

[install]
prefix = "${install_dir}/${target}"

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
	"${build_rust}" "${target}" rustbuild dist --jobs=${MAKE_JOBS}

	# copy distfiles
	log "copying ${target} distfiles to ${dist_dir}"
	mkdir -p "${dist_dir}"
	for _c in rustc rust-std cargo; do
		_f="${rustc_dir}/build/dist/${_c}-${target}-${triple_arch}.tar.gz"
		ln -f "${_f}" "${dist_dir}" \
			|| cp -f "${_f}" "${dist_dir}"
	done
	;;
install)	# install sets

	# install rustc and rust-std sets
	for _c in rustc rust-std cargo; do
		log "installing ${_c}-${target}"

		if [[ ! -r "${dist_dir}/${_c}-${target}-${triple_arch}.tar.gz" ]]; then
			echo "error: missing ${_c}-${target}-${triple_arch}.tar.gz" >&2
			exit 1
		fi

		tmpdir=`mktemp -d -p "${install_dir}" "rust-${target}.XXXXXX"` \
			|| exit 1
		tar zxf "${dist_dir}/${_c}-${target}-${triple_arch}.tar.gz" \
			-C "${tmpdir}"
		bash "${tmpdir}/${_c}-${target}-${triple_arch}/install.sh" \
			--prefix="${install_dir}/${target}"
		rm -rf -- "${tmpdir}"
	done

	# replace binaries with a wrapper (for LD_LIBRARY_PATH)
	for bin in rustc rustdoc cargo; do
		mv "${install_dir}/${target}/bin/${bin}" \
			"${install_dir}/${target}/bin/${bin}.bin"
		echo '#!/bin/sh' \
			>"${install_dir}/${target}/bin/${bin}"
		echo "LD_LIBRARY_PATH='${install_dir}/${target}/lib${LD_LIBRARY_PATH:+:}${LD_LIBRARY_PATH:-}' exec '${install_dir}/${target}/bin/${bin}.bin' \"\$@\"" \
			>>"${install_dir}/${target}/bin/${bin}"
		chmod 755 "${install_dir}/${target}/bin/${bin}"
	done

	# XXX let cc (aka clang) found libgcc.a
	ln -fs $(env PATH="${build_dir}/bin:${PATH}" gcc -print-libgcc-file-name) \
		"${install_dir}/${target}/lib/rustlib/${triple_arch}/lib"

	# XXX copy system lib ?
	;;
beta|nightly)	# prepare a release
	mkdir -p "${install_dir}/${target}"

	"${build_rust}" "${target}" fetch

	if [[ -z "${REBUILD:-}" && \
		-x "${install_dir}/${target}/bin/rustc" && \
		-r "${dist_dir}/rustc-${target}-src.tar.gz" && \
		"${install_dir}/${target}/bin/rustc" -nt \
			"${dist_dir}/rustc-${target}-src.tar.gz" ]]; then

		log "already up-to-date: ${target}"
		exit 0
	fi

	(
	"${build_rust}" "${target}" clean
	"${build_rust}" "${target}" extract
	"${build_rust}" "${target}" patch
	"${build_rust}" "${target}" configure
	"${build_rust}" "${target}" build
	"${build_rust}" "${target}" install
	) 2>&1 | tee "${install_dir}/${target}/build.log"
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
