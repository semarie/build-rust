#!/bin/ksh -eu
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

def_MAKE_JOBS=$(sysctl -n hw.ncpuonline)
MAKE_JOBS=${MAKE_JOBS:-${def_MAKE_JOBS}}

# practical variables (based on user-defined ones)
dist_dir="${install_dir}/dist"
crates_dir="${install_dir}/crates"

# use canonicalize version
mkdir -p "${install_dir}" "${build_dir}" "${dist_dir}" "${crates_dir}"
build_dir=$(readlink -fn "${build_dir}")
install_dir=$(readlink -fn "${install_dir}")
dist_dir=$(readlink -fn "${dist_dir}")
crates_dir=$(readlink -fn "${crates_dir}")

# cargo configuration
CARGO_HOME="${crates_dir}"
LIBSSH2_SYS_USE_PKG_CONFIG=1
LIBGIT2_SYS_USE_PKG_CONFIG=1
VERBOSE=${VERBOSE:-1}
RUST_BACKTRACE=${RUST_BACKTRACE:-1}
export CARGO_HOME LIBSSH2_SYS_USE_PKG_CONFIG LIBGIT2_SYS_USE_PKG_CONFIG VERBOSE CFLAGS RUST_BACKTRACE

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
rustc_xdir="${build_dir}/rustc-${target}-src"

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

	exec ${SUDO} pkg_add -aU 'python3' 'gmake' 'git' \
		'curl' 'cmake' 'bash' 'ggrep' 'gdb' \
		${_ccache} \
		${_llvm}
	;;
fetch)	# fetch latest rust version
	mkdir -p -- "${dist_dir}"
	refetch "rustc-${target}-src.tar.gz" \
		"${distfiles_rustc_base}/rustc-${target}-src.tar.gz" \
		"${dist_dir}/rustc-${target}-src.tar.gz" \
	;;
extract)	# extract rust version from dist_dir to build_dir
	"${build_rust}" "${target}" fetch

	if [[ -d "${build_dir}/rustc-${target}-src" ]]; then
		log "removing ${build_dir}/rustc-${target}-src"
		rm -rf -- "${build_dir}/rustc-${target}-src"
	fi
	mkdir -p -- "${build_dir}"

	log "extracting rustc-${target}-src.tar.gz"
	exec tar zxf "${dist_dir}/rustc-${target}-src.tar.gz" -C "${build_dir}"
	;;
patch)	# apply local patches
	[[ ! -d "${rustc_xdir}" ]] && \
		"${build_rust}" "${target}" extract

	log "patching ${target}"

	# create a link to avoid supporting -beta and -nightly differently
	if [ ! -e "${rustc_xdir}/vendor" ]; then
		ln -s "src/vendor" "${rustc_xdir}/vendor"
	fi

	## bootstrap: pass optimization flags: https://github.com/rust-lang/rust/issues/39900
	echo 'patching: bootstrap: pass optimization flags'
	sed -i 's/.*|s| !s.starts_with("-O") && !s.starts_with("\/O").*//' "${rustc_xdir}/src/bootstrap/lib.rs"

	## openssl-sys: libressl in -current isn't explicitly supported
	echo "patching: openssl-sys: libressl in -current isn't explicitly supported"
	# keep last supported version in hold space
	# when seeing last entry (error), replace with hold space (as generic)
	sed -i -e "/ => ('.', '.'),/h" \
		-e "/ => ('.', '.', '.'),/h" \
		-e "/_ => version_error(),/{g; s/(.*) =>/_ =>/; }" \
		"${rustc_xdir}/vendor/openssl-sys/build/main.rs"
	sed -i 's/"files":{[^}]*}/"files":{}/' "${rustc_xdir}/vendor/openssl-sys/.cargo-checksum.json"

	## filetime: don't try to use set_file_times_u()
	if grep -q '^1\.22\.' "${rustc_xdir}/version"; then
		echo "patching: filetime: don't try to use set_file_times_u()"
		sed -i 's/android/openbsd/g' "${rustc_xdir}/vendor/filetime/src/unix.rs"
		sed -i 's/"files":{[^}]*}/"files":{}/' "${rustc_xdir}/vendor/filetime/.cargo-checksum.json"
	fi

	## link to libc++
	if grep -q '^1\.2[23]\.' "${rustc_xdir}/version"; then
		echo "patching: link to libc++"
		sed -i 's/"estdc\+\+"/"c++"/' "${rustc_xdir}/src/librustc_llvm/build.rs"
		sed -i 's/"cargo:rustc-link-lib=gcc"/"cargo:rustc-link-lib=c++abi"/' "${rustc_xdir}/src/libunwind/build.rs"
	fi

	## use system libcompiler_rt
	if grep -q '^1.2[34567]\.' "${rustc_xdir}/version"; then
		echo "patching: use system libcompiler_rt"
		sed -i '/env::var("TARGET").unwrap();$/s/$/if target.contains("openbsd") { println!("cargo:rustc-link-search=native=\/usr\/lib"); println!("cargo:rustc-link-lib=static=compiler_rt"); return; }/' "${rustc_xdir}/src/libcompiler_builtins/build.rs"
	fi

	## use ninja for building binaryen
	if grep -q '^1.2[345]\.' "${rustc_xdir}/version"; then
		echo "patching: use ninja for building binaryen"
		sed -i '/\.build_target("binaryen")$/s/$/.generator("Ninja")/' "${rustc_xdir}/src/librustc_binaryen/build.rs"
	fi

	exit 0
	;;
rustbuild)	# rustbuild wrapper
	[[ ! -r "${rustc_xdir}/.configure-${target}" ]] \
		&& "${build_rust}" "${target}" configure

	# remove .cargo directory
	rm -rf -- "${build_dir}/.cargo"

	log "starting rustbuild ${@}"
	ulimit -c 0
	ulimit -d `ulimit -dH`
	cd "${build_dir}" && exec env \
		PATH="${build_dir}/bin:${PATH}" \
		"python3" "${rustc_xdir}/x.py" "$@"
	;;
clean)	# run rustbuild clean (do not remove llvm)
	[[ ! -d "${build_dir}/build" \
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
	for _p in cc c++; do
		if [[ "${ccache}" != "yes" ]]; then
			ln -fs "/usr/bin/${_p}" "${build_dir}/bin/${_p}"
		else	
			rm -f "${build_dir}/bin/${_p}" || true
			echo '#!/bin/sh' >"${build_dir}/bin/${_p}"
			echo "exec ccache /usr/bin/${_p} \"\${@}\"" \
				>>"${build_dir}/bin/${_p}"
			chmod 755 "${build_dir}/bin/${_p}"
		fi
	done

	ln -fs "cc" "${build_dir}/bin/gcc"
	ln -fs "c++" "${build_dir}/bin/g++"

	ln -fs "cc" "${build_dir}/bin/clang"
	ln -fs "c++" "${build_dir}/bin/clang++"
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
		if [[ ! -x "${dep_dir}/bin/rustfmt" ]]; then
			log "installing rustfmt-stable (from ports)"
			${SUDO} pkg_add -a rust-rustfmt
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
	log "info: required stage0:"
	sed -ne '/"compiler": {/,/}/p' "${rustc_xdir}/src/stage0.json"
	log "info: rustc -vV"
	"${dep_dir}/bin/rustc" -vV | sed 's/^/	/'
	log "info: cargo -vV"
	"${dep_dir}/bin/cargo" -vV | sed 's/^/	/'
	log "info: rustfmt -V"
	"${dep_dir}/bin/rustfmt" -V | sed 's/^/	/'

	# check rustc version
	case "${target}" in
	beta)
		required=$(sed -ne '/"compiler": {/,/}/p' "${rustc_xdir}/src/stage0.json" \
			| sed -ne 's/^ *"version": "\(.*\.\)0"/\1/p')
		if ! "${dep_dir}/bin/rustc" -vV | grep -qF "release: ${required}" 2>/dev/null; then
			log "error: build requires rustc ${required}"
			exit 1
		fi
		;;
	esac

	# llvm stuff
	if [[ ${llvm_config} != "no" ]]; then
		_llvm='llvm-config'
	else
		_llvm='#llvm-config'
	fi

	# generate config file
	mkdir -p "${build_dir}"
	cat >"${build_dir}/config.toml" <<EOF
[build]
rustc = "${dep_dir}/bin/rustc"
cargo = "${dep_dir}/bin/cargo"
rustfmt = "${dep_dir}/bin/rustfmt"
python = "/usr/local/bin/python3"
gdb = "/usr/local/bin/egdb"
#docs = false
vendor = true
extended = true
verbose = ${VERBOSE:-0}

[install]
prefix = "${install_dir}/${target}"

[dist]
src-tarball = false
missing-tools = true

[rust]
channel = "${target}"
codegen-tests = false
verbose-tests = true

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
	for _c in rustc rust-std cargo rustfmt; do
		_f="${build_dir}/build/dist/${_c}-${target}-${triple_arch}.tar.gz"
		ln -f "${_f}" "${dist_dir}" \
			|| cp -f "${_f}" "${dist_dir}"
	done
	;;
install)	# install sets

	# install rustc and required sets
	for _c in rustc rust-std cargo rustfmt; do
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
	for bin in rustc rustdoc cargo rustfmt; do
		mv "${install_dir}/${target}/bin/${bin}" \
			"${install_dir}/${target}/bin/${bin}.bin"
		echo '#!/bin/sh' \
			>"${install_dir}/${target}/bin/${bin}"
		echo "LD_LIBRARY_PATH='${install_dir}/${target}/lib${LD_LIBRARY_PATH:+:}${LD_LIBRARY_PATH:-}' exec '${install_dir}/${target}/bin/${bin}.bin' \"\$@\"" \
			>>"${install_dir}/${target}/bin/${bin}"
		chmod 755 "${install_dir}/${target}/bin/${bin}"
	done

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
	"${build_rust}" "${target}" clean \
		|| "${build_rust}" "${target}" clean-all
	"${build_rust}" "${target}" extract
	"${build_rust}" "${target}" patch
	"${build_rust}" "${target}" configure
	"${build_rust}" "${target}" build
	"${build_rust}" "${target}" install
	) 2>&1 | tee "${install_dir}/${target}/build.log"

	# ensure it has been installed
	if [[ -x "${install_dir}/${target}/bin/rustc" && \
		-r "${dist_dir}/rustc-${target}-src.tar.gz" && \
		"${install_dir}/${target}/bin/rustc" -nt \
		"${dist_dir}/rustc-${target}-src.tar.gz" ]]; then

		# keep a copy of latest good log
		log "task finished successfully: keeping build.log -> build-good.log"
		exec cp -f "${install_dir}/${target}/build.log" "${install_dir}/${target}/build-good.log"
	else
		log "task not finished: see build.log for detail"
		exit 1
	fi
	;;
test)	# invoke rustbuild for testing
	exec env RUST_BACKTRACE=0 "${build_rust}" "${target}" rustbuild test --jobs=${MAKE_JOBS} "$@"
	;;
buildbot)	# build and test
	# check if already running
	if [[ -r "${build_dir}/lock" ]]; then
		log "already running: $(cat ${build_dir}/lock)"
		exit 1
	fi
	# mark as running
	echo "started building ${target} at $(date) with pid $$" > "${build_dir}/lock"
	trap "rm -f -- '${build_dir}/lock'" EXIT ERR 1 2 3 13 15
	
	# force a configure
	"${build_rust}" "${target}" configure

	# build if need
	"${build_rust}" "${target}"

	# keep previous log
	test -r "${install_dir}/${target}/test.log" && \
		mv "${install_dir}/${target}/test.log" "${install_dir}/${target}/test-prev.log"

	# test
	set +e
	env RUST_BACKTRACE=0 "${build_rust}" "${target}" rustbuild test --jobs=${MAKE_JOBS} --no-fail-fast \
		| tee "${install_dir}/${target}/test.log"

	"${build_rust}" "${target}" buildbot-show
	exit 0
	;;
buildbot-show)	# show summary of failures
	ls -l "${install_dir}/${target}/test.log"
	echo ''
	echo 'Summary:'
	sed -ne '/^failures:$/,/^test result: FAILED/p' "${install_dir}/${target}/test.log" \
		| grep  -e '^    \[' \
			-e '^    [^ ]*$' \
			-e '^    [^ ].*(line ' \
			-e 'FAILED'
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
