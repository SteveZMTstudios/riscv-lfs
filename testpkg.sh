#!/bin/bash

# LFS 包安装与基本功能检查脚本
# 在 chroot 内运行

#set -e  # 遇错即停（可按需注释掉）

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
NC="\e[0m"  # No Color

PASS=0
FAIL=0
WARN=0
CHECK_TOOLS_ORIGIN=${CHECK_TOOLS_ORIGIN:-1}

# 记录结果
log() {
    echo -e "$1"
}

resolve_path() {
    local path=$1
    if command -v readlink &>/dev/null; then
        readlink -f "$path" 2>/dev/null || echo "$path"
        return 0
    fi
    echo "$path"
}

check_cmd_origin() {
    local pkg=$1
    local cmd=$2
    local path=$3
    local real
    local first
    local file_type
    local ldd_out
    local elf_out

    real=$(resolve_path "$path")

    if echo "$real" | grep -q '^/tools/'; then
        log "${RED}[FAIL]${NC} $pkg: '$cmd' resolves to $real (from /tools)."
        FAIL=$((FAIL+1))
        return 1
    fi

    if command -v file &>/dev/null; then
        file_type=$(file -b -- "$real" 2>/dev/null || true)
        case "$file_type" in
            *text*|*script*)
                first=$(head -n 1 "$real" 2>/dev/null || true)
                if echo "$first" | grep -q '^#!/tools/'; then
                    log "${RED}[FAIL]${NC} $pkg: '$cmd' shebang points to /tools."
                    FAIL=$((FAIL+1))
                    return 1
                fi
                ;;
        esac
    fi

    if command -v readelf &>/dev/null; then
        elf_out=$(readelf -l "$real" 2>/dev/null || true)
        if echo "$elf_out" | grep -q '/tools/'; then
            log "${RED}[FAIL]${NC} $pkg: '$cmd' ELF interpreter references /tools."
            FAIL=$((FAIL+1))
            return 1
        fi
    fi

    if command -v ldd &>/dev/null; then
        ldd_out=$(ldd "$real" 2>/dev/null || true)
        if echo "$ldd_out" | grep -q '/tools/'; then
            log "${RED}[FAIL]${NC} $pkg: '$cmd' links against /tools libs."
            FAIL=$((FAIL+1))
            return 1
        fi
    fi

    return 0
}

check_no_tools_env() {
    if [ "$CHECK_TOOLS_ORIGIN" != "1" ]; then
        return 0
    fi

    if echo ":$PATH:" | grep -q ':/tools/'; then
        log "${RED}[FAIL]${NC} Environment: PATH contains /tools."
        FAIL=$((FAIL+1))
        return 1
    fi

    if [ -n "${LD_LIBRARY_PATH:-}" ] && echo ":$LD_LIBRARY_PATH:" | grep -q ':/tools/'; then
        log "${RED}[FAIL]${NC} Environment: LD_LIBRARY_PATH contains /tools."
        FAIL=$((FAIL+1))
        return 1
    fi

    if [ -d /tools ]; then
        log "${YELLOW}[WARN]${NC} Environment: /tools exists (cleanup not done)."
        WARN=$((WARN+1))
        return 0
    fi

    log "${GREEN}[PASS]${NC} Environment: no /tools in PATH/LD_LIBRARY_PATH."
    PASS=$((PASS+1))
    return 0
}

check_no_tools_ldconfig() {
    if [ "$CHECK_TOOLS_ORIGIN" != "1" ]; then
        return 0
    fi

    if command -v ldconfig &>/dev/null; then
        if ldconfig -p | grep -q '/tools/'; then
            log "${RED}[FAIL]${NC} Linker cache: entries from /tools detected."
            FAIL=$((FAIL+1))
            return 1
        fi
    fi

    return 0
}

check_path_absent() {
    local pkg=$1
    local path=$2

    if [ -e "$path" ] || [ -L "$path" ]; then
        log "${RED}[FAIL]${NC} $pkg: unexpected path '$path' exists."
        FAIL=$((FAIL+1))
        return 1
    fi

    log "${GREEN}[PASS]${NC} $pkg: path '$path' absent."
    PASS=$((PASS+1))
    return 0
}

check_no_lib64_pollution() {
    if [ "$CHECK_TOOLS_ORIGIN" != "1" ]; then
        return 0
    fi

    # check_path_absent Lib64-Pollution "/lib64" || return 1
    check_path_absent Lib64-Pollution "/usr/lib64" || return 1
    return 0
}

check_symlink() {
    local pkg=$1
    local link=$2
    local target=$3
    local actual
    local expected

    if [ ! -L "$link" ]; then
        log "${RED}[FAIL]${NC} $pkg: '$link' is not a symlink. Reinstalling the package is preferred over creating it manually."
        FAIL=$((FAIL+1))
        return 1
    fi

    actual=$(readlink -f "$link" 2>/dev/null || true)
    expected=$(readlink -f "$target" 2>/dev/null || echo "$target")

    if [ "$actual" != "$expected" ]; then
        log "${RED}[FAIL]${NC} $pkg: '$link' -> '$actual' (expected '$expected')."
        FAIL=$((FAIL+1))
        return 1
    fi

    log "${GREEN}[PASS]${NC} $pkg: symlink '$link' -> '$target'."
    PASS=$((PASS+1))
    return 0
}

check_command_symlink() {
    local pkg=$1
    local name=$2
    local target_name=$3
    local link
    local actual
    local expected
    local target_path

    for link in "/usr/bin/$name" "/usr/sbin/$name"; do
        if [ -L "$link" ]; then
            actual=$(readlink -f "$link" 2>/dev/null || true)
            target_path=$(command -v "$target_name" 2>/dev/null || true)
            if [ -z "$target_path" ]; then
                log "${RED}[FAIL]${NC} $pkg: target command '$target_name' not found for '$name'."
                FAIL=$((FAIL+1))
                return 1
            fi

            expected=$(readlink -f "$target_path" 2>/dev/null || echo "$target_path")
            if [ "$actual" != "$expected" ]; then
                log "${RED}[FAIL]${NC} $pkg: '$link' -> '$actual' (expected '$expected')."
                FAIL=$((FAIL+1))
                return 1
            fi

            log "${GREEN}[PASS]${NC} $pkg: symlink '$link' -> '$target_name'."
            PASS=$((PASS+1))
            return 0
        fi
    done

    log "${RED}[FAIL]${NC} $pkg: neither '/usr/bin/$name' nor '/usr/sbin/$name' exists as a symlink. Reinstalling systemd is preferred over creating it manually."
    FAIL=$((FAIL+1))
    return 1
}

check_elf_arch() {
    local pkg=$1
    local path=$2
    local file_out

    file_out=$(file -L "$path" 2>/dev/null || true)
    if echo "$file_out" | grep -Eq 'RISC-V|riscv64'; then
        log "${GREEN}[PASS]${NC} $pkg: '$path' is RISC-V ELF."
        PASS=$((PASS+1))
        return 0
    fi

    log "${RED}[FAIL]${NC} $pkg: '$path' is not recognized as RISC-V ELF. Output: $file_out"
    FAIL=$((FAIL+1))
    return 1
}

check_cmd_arch() {
    local pkg=$1
    local cmd=${2:-$1}
    local path

    path=$(command -v "$cmd" 2>/dev/null || true)
    if [ -z "$path" ]; then
        log "${RED}[FAIL]${NC} $pkg: command '$cmd' not found for architecture check."
        FAIL=$((FAIL+1))
        return 1
    fi

    check_elf_arch "$pkg" "$path"
}

# 检查命令是否存在
check_cmd() {
    local pkg=$1
    local cmd=${2:-$pkg}
    if command -v "$cmd" &>/dev/null; then
        local path
        path=$(command -v "$cmd")
        if [ "$CHECK_TOOLS_ORIGIN" = "1" ]; then
            if ! check_cmd_origin "$pkg" "$cmd" "$path"; then
                return 1
            fi
        fi
        log "${GREEN}[PASS]${NC} $pkg: command '$cmd' found."
        PASS=$((PASS+1))
        return 0
    else
        log "${RED}[FAIL]${NC} $pkg: command '$cmd' not found."
        FAIL=$((FAIL+1))
        return 1
    fi
}

# 检查文件或目录是否存在
check_file() {
    local pkg=$1
    local path=$2
    if ls "$path" &>/dev/null; then
        log "${GREEN}[PASS]${NC} $pkg: file(s) '$path' exist."
        PASS=$((PASS+1))
        return 0
    else
        log "${RED}[FAIL]${NC} $pkg: file(s) '$path' not found."
        FAIL=$((FAIL+1))
        return 1
    fi
}

# 检查多个文件路径中的任意一个是否存在
check_any_file() {
    local pkg=$1
    shift
    local path

    for path in "$@"; do
        if ls "$path" &>/dev/null; then
            log "${GREEN}[PASS]${NC} $pkg: file(s) '$path' exist."
            PASS=$((PASS+1))
            return 0
        fi
    done

    log "${RED}[FAIL]${NC} $pkg: none of the expected file paths exist: $*"
    FAIL=$((FAIL+1))
    return 1
}

# 检查 pkg-config 模块
check_pkgconfig() {
    local pkg=$1
    local module=$2
    if pkg-config --exists "$module" &>/dev/null; then
        log "${GREEN}[PASS]${NC} $pkg: pkg-config module '$module' found."
        PASS=$((PASS+1))
        return 0
    else
        log "${RED}[FAIL]${NC} $pkg: pkg-config module '$module' not found."
        FAIL=$((FAIL+1))
        return 1
    fi
}

# 检查库文件
check_lib() {
    local pkg=$1
    local lib=$2
    if ldconfig -p | grep -q "$lib"; then
        log "${GREEN}[PASS]${NC} $pkg: library '$lib' registered in ldconfig."
        PASS=$((PASS+1))
        return 0
    else
        log "${YELLOW}[WARN]${NC} $pkg: library '$lib' not found via ldconfig (maybe static or in non-standard path)."
        WARN=$((WARN+1))
        return 1
    fi
}

# 运行简单测试并检查输出
run_test() {
    local pkg=$1
    local cmd="$2"
    local expected="$3"
    local desc=${4:-"$cmd"}
    local output
    local status
    output=$(eval "$cmd" 2>&1)
    status=$?
    if [ "$status" -ne 0 ]; then
        log "${RED}[FAIL]${NC} $pkg: $desc -> command failed with exit code $status. Output: $output"
        FAIL=$((FAIL+1))
        return 1
    fi

    if echo "$output" | grep -q "$expected"; then
        log "${GREEN}[PASS]${NC} $pkg: $desc -> matched '$expected'."
        PASS=$((PASS+1))
        return 0
    else
        log "${RED}[FAIL]${NC} $pkg: $desc -> did not match '$expected'. Output: $output"
        FAIL=$((FAIL+1))
        return 1
    fi
}

# 检查 Python 模块
check_python_mod() {
    local pkg=$1
    local module=$2
    if python3 -c "import $module" 2>/dev/null; then
        log "${GREEN}[PASS]${NC} $pkg: Python module '$module' importable."
        PASS=$((PASS+1))
        return 0
    else
        log "${RED}[FAIL]${NC} $pkg: Python module '$module' cannot be imported."
        FAIL=$((FAIL+1))
        return 1
    fi
}

# 检查 Perl 模块
check_perl_mod() {
    local pkg=$1
    local module=$2
    if perl -M"$module" -e 1 2>/dev/null; then
        log "${GREEN}[PASS]${NC} $pkg: Perl module '$module' available."
        PASS=$((PASS+1))
        return 0
    else
        log "${RED}[FAIL]${NC} $pkg: Perl module '$module' not found."
        FAIL=$((FAIL+1))
        return 1
    fi
}

SMOKE_DIR=${SMOKE_DIR:-/tmp/lfs-smoke}
CC=${CC:-gcc}
mkdir -p "$SMOKE_DIR"

cleanup() {
    if [ "${KEEP_SMOKE_DIR:-0}" = "1" ] || [ "$FAIL" -ne 0 ]; then
        log "${YELLOW}[WARN]${NC} keeping $SMOKE_DIR for inspection."
        return 0
    fi
    rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT

# 编译并运行简单的 C 测试程序
compile_and_run() {
    local pkg=$1
    local cflags="$2"
    local libs="$3"
    local code="$4"
    local expected="$5"
    local src
    local bin
    local output
    local tag

    tag=$(echo "$pkg" | tr -c 'a-zA-Z0-9' '_')
    src=$(mktemp "$SMOKE_DIR/${tag}.XXXX.c")
    bin="${src%.c}"

    printf '%b' "$code" > "$src"

    if ! $CC $cflags "$src" $libs -o "$bin" >"$src.build.log" 2>&1; then
        log "${RED}[FAIL]${NC} $pkg: compile failed. See $src.build.log"
        FAIL=$((FAIL+1))
        return 1
    fi

    output=$("$bin" 2>&1)
    if [ -n "$expected" ] && ! echo "$output" | grep -q "$expected"; then
        log "${RED}[FAIL]${NC} $pkg: smoke output did not match '$expected'. Output: $output"
        FAIL=$((FAIL+1))
        return 1
    fi

    log "${GREEN}[PASS]${NC} $pkg: smoke test ok."
    PASS=$((PASS+1))
    return 0
}

echo "========== LFS System Package Verification =========="
echo "Date: $(date)"
echo

check_no_tools_env
check_no_tools_ldconfig
check_no_lib64_pollution

# ---- 文档/基础 ----
check_file Man-pages-6.17 "/usr/share/man/man2/open.2"
check_file Iana-Etc-20260202 "/etc/protocols"
check_file Glibc-2.43 "/usr/lib/libc.so.6"
check_cmd Glibc "ldd"
run_test Glibc "ldd --version" "ldd"
run_test Glibc "getconf GNU_LIBC_VERSION" "glibc 2.43"

# ---- 压缩库 ----
check_file Zlib-1.3.2 "/usr/include/zlib.h"
check_lib Zlib "libz.so"
compile_and_run Zlib "" "-lz" '#include <zlib.h>\n#include <stdio.h>\nint main(void){const char* v=zlibVersion(); if(!v) return 1; puts(v); return 0;}' "1.3.2"
check_file Bzip2-1.0.8 "/usr/bin/bzip2"
run_test Bzip2 "bzip2 --help" "usage"
compile_and_run Bzip2 "" "-lbz2" '#include <bzlib.h>\n#include <stdio.h>\nint main(void){const char* v=BZ2_bzlibVersion(); if(!v) return 1; puts(v); return 0;}' "1.0.8"
check_file Xz-5.8.2 "/usr/bin/xz"
run_test Xz "xz --version" "xz"
compile_and_run Xz "" "-llzma" '#include <lzma.h>\n#include <stdio.h>\nint main(void){const char* v=lzma_version_string(); if(!v) return 1; puts(v); return 0;}' "5.8.2"
check_file Lz4-1.10.0 "/usr/bin/lz4"
compile_and_run Lz4 "" "-llz4" '#include <lz4.h>\n#include <stdio.h>\nint main(void){const char* v=LZ4_versionString(); if(!v) return 1; puts(v); return 0;}' "1.10.0"
check_file Zstd-1.5.7 "/usr/bin/zstd"
compile_and_run Zstd "" "-lzstd" '#include <zstd.h>\n#include <stdio.h>\nint main(void){const char* v=ZSTD_versionString(); if(!v) return 1; puts(v); return 0;}' "1.5.7"

# ---- 工具 ----
check_cmd File "file"
run_test File "file -L /bin/sh" "ELF"
check_file Readline-8.3 "/usr/include/readline/readline.h"
check_lib Readline "libreadline.so"
compile_and_run Readline "" "-lreadline" '#include <stdio.h>\n#include <readline/readline.h>\nint main(void){ if(!rl_library_version) return 1; puts(rl_library_version); return 0; }' "8.3"
check_file Pcre2-10.47 "/usr/include/pcre2.h"
check_lib Pcre2 "libpcre2-8.so"
compile_and_run Pcre2 "-DPCRE2_CODE_UNIT_WIDTH=8" "-lpcre2-8" '#include <stdio.h>\n#include <pcre2.h>\nint main(void){int error; PCRE2_SIZE erroffset; PCRE2_SPTR pattern=(PCRE2_SPTR)"abc"; pcre2_code *re=pcre2_compile(pattern, PCRE2_ZERO_TERMINATED, 0, &error, &erroffset, NULL); if(!re) return 1; pcre2_code_free(re); puts("ok"); return 0;}' "ok"
check_cmd M4 "m4"
run_test M4 "m4 --version" "m4"
check_cmd Bc "bc"
run_test Bc "bc --version" "bc"
check_cmd Flex "flex"
run_test Flex "flex --version" "flex"
check_cmd Tcl "tclsh"
run_test Tcl "echo 'puts ok' | tclsh" "ok"
check_cmd Expect "expect"
run_test Expect "echo 'puts ok' | expect -" "ok"
check_cmd DejaGNU "runtest"  # 或 runtest --version
check_cmd Pkgconf "pkg-config"
run_test Pkgconf "pkg-config --version" "2.5.1"

# ---- 工具链 ----
check_cmd Binutils-2.46.0 "ld"
run_test Binutils "ld --version" "GNU ld"
check_file GMP-6.3.0 "/usr/include/gmp.h"
check_lib GMP "libgmp.so"
compile_and_run GMP "" "-lgmp" '#include <gmp.h>\n#include <stdio.h>\nint main(void){ if(!gmp_version) return 1; puts(gmp_version); return 0; }' "6.3.0"
check_file MPFR-4.2.2 "/usr/include/mpfr.h"
check_lib MPFR "libmpfr.so"
compile_and_run MPFR "" "-lmpfr" '#include <mpfr.h>\n#include <stdio.h>\nint main(void){ const char* v=mpfr_get_version(); if(!v) return 1; puts(v); return 0; }' "4.2.2"
check_file MPC-1.3.1 "/usr/include/mpc.h"
check_lib MPC "libmpc.so"
compile_and_run MPC "" "-lmpc" '#include <mpc.h>\n#include <stdio.h>\nint main(void){ const char* v=mpc_get_version(); if(!v) return 1; puts(v); return 0; }' "1.3.1"
check_cmd GCC-15.2.0 "gcc"
run_test GCC "gcc --version" "gcc"
run_test GCC "echo 'int main(){}' | gcc -x c - -o /tmp/testgcc && /tmp/testgcc && echo ok" "ok"

# ---- 属性/权限库 ----
check_file Attr-2.5.2 "/usr/include/attr/libattr.h"
check_file Acl-2.3.2 "/usr/include/acl/libacl.h"
check_file Libcap-2.77 "/usr/include/sys/capability.h"
check_cmd Libcap "capsh"
run_test Libcap "capsh --print" "Current"
check_file Libxcrypt-4.5.2 "/usr/include/crypt.h"
compile_and_run Libxcrypt "" "-lcrypt" '#include <crypt.h>\n#include <stdio.h>\nint main(void){ char* r=crypt("pw","aa"); if(!r) return 1; puts(r); return 0; }' "aa"
check_file Shadow-4.19.3 "/usr/bin/passwd"
run_test Shadow "passwd --help" "Usage"

# ---- 文本处理/编译工具 ----
check_file Ncurses-6.6 "/usr/include/curses.h"
check_lib Ncurses "libncursesw.so"
compile_and_run Ncurses "" "-lncursesw" '#include <curses.h>\n#include <stdio.h>\nint main(void){ const char* v=curses_version(); if(!v) return 1; puts(v); return 0; }' "6.6"
check_cmd Sed "sed"
run_test Sed "sed --version" "sed"
check_cmd Psmisc "pstree"
run_test Psmisc "pstree --version" "pstree"
check_cmd Gettext "gettext"
run_test Gettext "gettext --version" "gettext"
check_cmd Bison "bison"
run_test Bison "bison --version" "bison"
check_cmd Grep "grep"
run_test Grep "grep --version" "grep"
check_cmd Bash "bash"
run_test Bash "bash -c 'echo ok'" "ok"
check_cmd Libtool "libtool"
run_test Libtool "libtool --version" "libtool"
check_file GDBM-1.26 "/usr/include/gdbm.h"
compile_and_run GDBM "" "-lgdbm" '#include <gdbm.h>\n#include <stdio.h>\nint main(void){ GDBM_FILE db=gdbm_open("/tmp/gdbm_smoke", 0, GDBM_NEWDB, 0600, 0); if(!db) return 1; gdbm_close(db); puts("ok"); return 0; }' "ok"
check_cmd Gperf "gperf"
run_test Gperf "gperf --version" "gperf"
check_file Expat-2.7.4 "/usr/include/expat.h"
compile_and_run Expat "" "-lexpat" '#include <expat.h>\n#include <stdio.h>\nint main(void){ XML_Parser p=XML_ParserCreate(NULL); if(!p) return 1; XML_ParserFree(p); puts("ok"); return 0; }' "ok"
check_cmd Inetutils "ping"
run_test Inetutils "ping -V" "ping"

# ---- 编辑器/查看器 ----
check_cmd Less "less"
run_test Less "less --version" "less"
check_cmd Vim "vim"
run_test Vim "vim --version" "VIM"

# ---- 脚本语言 ----
check_cmd Perl-5.42.0 "perl"
run_test Perl "perl -e 'print qq/ok\n/'" "ok"
check_perl_mod XML::Parser "XML::Parser"
check_cmd Intltool "intltoolize"
run_test Intltool "intltoolize --version" "intltoolize"

# ---- 构建工具 ----
check_cmd Autoconf-2.72 "autoconf"
run_test Autoconf "autoconf --version" "autoconf"
check_cmd Automake-1.18.1 "automake"
run_test Automake "automake --version" "automake"

# ---- 加密/网络 ----
check_cmd OpenSSL-3.6.1 "openssl"
check_cmd_arch OpenSSL "openssl"
run_test OpenSSL "openssl version" "OpenSSL"
compile_and_run OpenSSL "" "-lssl -lcrypto" '#include <openssl/crypto.h>\n#include <stdio.h>\nint main(void){ const char* v=OpenSSL_version(OPENSSL_VERSION); if(!v) return 1; puts(v); return 0; }' "OpenSSL"

# ---- 开发库 ----
check_any_file Libelf "/usr/include/libelf.h" "/usr/include/elfutils/libelf.h"
check_lib Libelf "libelf.so"
compile_and_run Libelf "" "-lelf" '#include <libelf.h>\n#include <stdio.h>\nint main(void){ if(elf_version(EV_CURRENT)==EV_NONE) return 1; puts("ok"); return 0; }' "ok"
check_file Libffi-3.5.2 "/usr/include/ffi.h"
check_lib Libffi "libffi.so"
compile_and_run Libffi "" "-lffi" '#include <ffi.h>\n#include <stdio.h>\nint main(void){ ffi_cif cif; ffi_type* args[1]; args[0]=&ffi_type_uint32; if(ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 1, &ffi_type_uint32, args)!=FFI_OK) return 1; puts("ok"); return 0; }' "ok"

# ---- 数据库 ----
check_cmd Sqlite-3510200 "sqlite3"
check_cmd_arch Sqlite "sqlite3"
run_test Sqlite "sqlite3 :memory: 'select 1;'" "1"
compile_and_run Sqlite "" "-lsqlite3" '#include <sqlite3.h>\n#include <stdio.h>\nint main(void){ const char* v=sqlite3_libversion(); if(!v) return 1; puts(v); return 0; }' "3.51.2"

# ---- Python ----
check_cmd Python-3.14.3 "python3"
check_cmd_arch Python "python3"
run_test Python "python3 --version" "Python"
run_test Flit-Core "python3 -c 'import flit_core'" ""
check_python_mod Packaging "packaging"
check_python_mod Wheel "wheel"
check_python_mod Setuptools "setuptools"
run_test Packaging "python3 -c 'import packaging; print(packaging.__version__)'" "26.0"
run_test Wheel "python3 -c 'import wheel; print(wheel.__version__)'" "0.46.3"
run_test Setuptools "python3 -c 'import setuptools; print(setuptools.__version__)'" "82.0.0"
compile_and_run Python-CAPI "-I/usr/include/python3.14" "-lpython3.14" '#include <Python.h>\n#include <stdio.h>\nint main(void){ Py_Initialize(); const char* v=Py_GetVersion(); if(!v) return 1; puts(v); Py_Finalize(); return 0; }' "3.14"

# ---- Ninja/Meson ----
check_cmd Ninja-1.13.2 "ninja"
run_test Ninja "ninja --version" "1.13.2"
check_cmd Meson-1.10.1 "meson"
run_test Meson "meson --version" "1.10.1"

# ---- 内核/模块工具 ----
check_cmd Kmod-34.2 "kmod"
check_cmd_arch Kmod "kmod"
run_test Kmod "kmod --version" "kmod"
compile_and_run Kmod "" "-lkmod" '#include <libkmod.h>\n#include <stdio.h>\nint main(void){ struct kmod_ctx* ctx=kmod_new(NULL, NULL); if(!ctx) return 1; kmod_unref(ctx); puts("ok"); return 0; }' "ok"
check_cmd Coreutils-9.10 "ls"
run_test Coreutils "ls --version" "coreutils"
check_cmd Diffutils-3.12 "diff"
run_test Diffutils "diff --version" "diffutils"
check_cmd Gawk-5.3.2 "gawk"
run_test Gawk "gawk --version" "GNU Awk"
check_cmd Findutils-4.10.0 "find"
run_test Findutils "find --version" "findutils"
check_cmd Groff-1.23.0 "groff"
run_test Groff "groff --version" "groff"
if check_cmd GRUB-2.14 "grub-install"; then  # 可能无
    run_test GRUB "grub-install --version" "grub-install"
fi
check_cmd Gzip-1.14 "gzip"
run_test Gzip "gzip --version" "gzip"
check_cmd IPRoute2-6.18.0 "ip"
run_test IPRoute2 "ip -V" "iproute2"
check_cmd Kbd-2.9.0 "kbd_mode"
check_cmd Kbd "dumpkeys"
run_test Kbd "dumpkeys --version" "dumpkeys"
check_file Libpipeline-1.5.8 "/usr/include/pipeline.h"
check_cmd Make-4.4.1 "make"
run_test Make "make --version" "GNU Make"
check_cmd Patch-2.8 "patch"
run_test Patch "patch --version" "patch"
check_cmd Tar-1.35 "tar"
run_test Tar "tar --version" "tar"
check_cmd Texinfo-7.2 "makeinfo"
run_test Texinfo "makeinfo --version" "texinfo"

# ---- 系统与服务 ----
check_file Systemd-259.1 "/usr/lib/systemd/systemd"
check_file Systemd-259.1 "/usr/include/systemd/sd-daemon.h"
check_lib Systemd "libsystemd.so"
check_cmd Systemctl "systemctl"  # 可能不会运行，但命令应存在
check_cmd_arch Systemctl "systemctl"
run_test Systemctl "systemctl --version" "systemd 259"
check_command_symlink Systemd "halt" "systemctl"
check_command_symlink Systemd "poweroff" "systemctl"
check_command_symlink Systemd "reboot" "systemctl"
check_command_symlink Systemd "shutdown" "systemctl"
check_command_symlink Systemd "systemd-resolve" "resolvectl"
check_command_symlink Systemd "run0" "systemd-run"
check_command_symlink Systemd "systemd-umount" "systemd-mount"
compile_and_run Systemd "$(pkg-config --cflags libsystemd 2>/dev/null)" "$(pkg-config --libs libsystemd 2>/dev/null)" '#include <systemd/sd-daemon.h>\n#include <stdio.h>\nint main(void){ int r=sd_booted(); printf("booted=%d\\n",r); return (r>=0)?0:1; }' "booted"
check_file D-Bus-1.16.2 "/usr/bin/dbus-daemon"
check_file D-Bus-1.16.2 "/usr/include/dbus-1.0/dbus/dbus.h"
check_lib D-Bus "libdbus-1.so"
check_cmd D-Bus "dbus-daemon"
check_cmd_arch D-Bus "dbus-daemon"
run_test D-Bus "dbus-daemon --version" "D-Bus"
compile_and_run D-Bus "$(pkg-config --cflags dbus-1 2>/dev/null)" "$(pkg-config --libs dbus-1 2>/dev/null)" '#include <dbus/dbus.h>\n#include <stdio.h>\nint main(void){ int major, minor, micro; dbus_get_version(&major, &minor, &micro); printf("%d.%d.%d\\n", major, minor, micro); return 0; }' "1.16.2"
check_cmd Man-DB-2.13.1 "man"
run_test Man-DB "man --version" "2.13.1"
check_cmd Procps-ng-4.0.6 "ps"
run_test Procps-ng "ps --version" "procps"
check_cmd Util-linux-2.41.3 "mount"
run_test Util-linux "mount --version" "util-linux"
check_cmd E2fsprogs-1.47.3 "e2fsck"
check_cmd_arch E2fsprogs "e2fsck"
run_test E2fsprogs "e2fsck -V" "1.47.3"
check_file E2fsprogs-lib "/usr/include/et/com_err.h"
check_lib E2fsprogs-lib "libcom_err.so"
compile_and_run E2fsprogs-lib "" "-lcom_err" '#include <et/com_err.h>\n#include <stdio.h>\nint main(void){ const char* v=error_message(0); puts(v?v:"(null)"); return 0; }' "Success"

# ---- 额外 Python 包 ----
check_python_mod MarkupSafe "markupsafe"
check_python_mod Jinja2 "jinja2"
run_test MarkupSafe "python3 -c 'import markupsafe; print(markupsafe.__version__)'" "3.0.3"
run_test Jinja2 "python3 -c 'import jinja2; print(jinja2.__version__)'" "3.1.6"

echo
echo "===================== Summary ====================="
echo -e "Passed: $PASS"
echo -e "Failed: $FAIL"
echo -e "Warnings: $WARN"

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All critical checks passed.${NC}"
else
    echo -e "${RED}Some checks failed. Review the log above.${NC}"
fi
