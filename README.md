# build-rust

build-rust is a shell script for getting a rust beta or nightly running on
OpenBSD.

The script works by using the stable rust from the OpenBSD package repo to
build a beta rust, then (if you want a nightly) it uses this beta rust to build
a nightly rust. It also deals with ensuring the right cargo version is used at
each stage.

## Quick Start

First:

```
$ ./build init
```

This step uses `doas(1)` to install some packages. Please read the script to
ensure you are happy with the commands that will be run as root.

Now run:
```
$ ./build <target>
```

Where `<target>` is either `beta` or `nightly`. If you choose `nightly` but
have not yet built  `beta`, then `beta` will be built first automatically.

(Note that `sh build.sh ...` will not work. You must use `./build.sh ...`)

Once this is done you will have a working rust environment (including cargo) in
`install_dir/<target>`. If you want this to be your default rustc and cargo,
then you probably want to add `install_dir/<target>/bin` to your `PATH` in your
shell rc.

rust encodes an rpath by default, so you should *not* have to set an
`LD_LIBRARY_PATH`.

## Why is the Installed Cargo Old?

The script uses the version of cargo indicated in upstream `src/stage0.txt`.
This is not necessarily the newest cargo, but is guaranteed to work for
bootstrapping.

If you would like a newer cargo, you can either manually build one off the
upstream master branch, or you can use the bootstrap cargo to install a new one
in `~/.cargo/bin`:

```
$ cargo install cargo
```

If you want that as your default cargo, don't forget to add it to the `PATH`.

## I get an Error About Linking -lstdc++ Failing.

E.g.
```
error: linking with `cc` failed: exit code: 1
  |
  = note: "cc" "-Wl,--as-needed" "-Wl,-z,noexecstack" ...
...
  = note: /usr/bin/ld: cannot find -lestdc++
          collect2: ld returned 1 exit status

error: aborting due to previous error
```

Some parts of the rust standard library (notably the compiler plugin APIs) link
`libestdc++`, however generally speaking, this is not a strict dependency for
all rust programs.

If you encounter this error, you probably want to use `eg++` as the linker
instead of the base `g++`. A convenient way to do this is to have your project
use `eg++` if the host system is OpenBSD. For example, for an amd64 system, add
in `.cargo/config`:

```
[target.x86_64-unknown-openbsd]
linker = "eg++"
```

## Why is this Script Needed?

### Reason 1: Cross compiling.

Under normal circumstances, rust upstream would cross compile beta and nightly
rust on their Linux machines, making the resulting binaries available via
`rustup`. However, OpenBSD has a modified linker meaning that cross compiled
binaries do not run.

There are ongoing efforts to use clang/LLVM as OpenBSD's base compiler and
linker. It is hoped that the linker customisations required will be pushed
upstream so cross compiling to OpenBSD becomes easier.

### Reason 2: No Backward Compatibility

OpenBSD makes no attempt to be backward compatible. At any given time there are
two supported stable releases of OpenBSD, and a frequently regenerated
developer version called `-current`. Generally speaking, binaries from an older
stable release do not run on a newer stable release. Furthermore, there is no
guarantee that the binary built on last week's `-current` will work on this
week's. Compatibility breakage can occur not only at the library level, but
also at the ABI level.

Even if the Rust upstream could cross compile to OpenBSD, it's not clear which
version's of OpenBSD would be useful to target.
