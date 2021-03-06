#!/bin/bash
# Top-level build script called from Dockerfile

# Stop at any error, show all commands
set -ex

# Set build environment variables
MY_DIR=$(dirname "${BASH_SOURCE[0]}")
. $MY_DIR/build_env.sh

# Dependencies for compiling Python that we want to remove from
# the final image after compiling Python
# GPG installed to verify signatures on Python source tarballs.
PYTHON_COMPILE_DEPS="zlib-devel bzip2-devel ncurses-devel sqlite-devel \
readline-devel tk-devel gdbm-devel db4-devel libpcap-devel\
xz-devel gpg atlas-devel libev-devel libev snappy-devel
python-imaging openjpeg-devel freetype-devel libpng-devel \
libffi-devel python-lxml postgresql95-libs \
postgresql95-devel lapack-devel python \
python-devel python-setuptools pcre pcre-devel \
pandoc"

# Libraries that are allowed as part of the manylinux1 profile
MANYLINUX1_DEPS="glibc-devel libstdc++-devel glib2-devel libX11-devel \
libXext-devel libXrender-devel mesa-libGL-devel \
libICE-devel libSM-devel ncurses-devel"

# Centos 5 is EOL and is no longer available from the usual mirrors, so switch
# to http://vault.centos.org
# From: https://github.com/rust-lang/rust/pull/41045
# The location for version 5 was also removed, so now only the specific release
# (5.11) can be referenced.
sed -i 's/enabled=1/enabled=0/' /etc/yum/pluginconf.d/fastestmirror.conf
sed -i 's/mirrorlist/#mirrorlist/' /etc/yum.repos.d/*.repo
sed -i 's/#\(baseurl.*\)mirror.centos.org\/centos\/$releasever/\1vault.centos.org\/5.11/' /etc/yum.repos.d/*.repo

# Get build utilities
source $MY_DIR/build_utils.sh

# See https://unix.stackexchange.com/questions/41784/can-yum-express-a-preference-for-x86-64-over-i386-packages
echo "multilib_policy=best" >> /etc/yum.conf

# https://hub.docker.com/_/centos/
# "Additionally, images with minor version tags that correspond to install
# media are also offered. These images DO NOT recieve updates as they are
# intended to match installation iso contents. If you choose to use these
# images it is highly recommended that you include RUN yum -y update && yum
# clean all in your Dockerfile, or otherwise address any potential security
# concerns."
# Decided not to clean at this point: https://github.com/pypa/manylinux/pull/129
yum -y update

# EPEL support
yum -y install wget
# https://dl.fedoraproject.org/pub/epel/5/x86_64/epel-release-5-4.noarch.rpm
cp $MY_DIR/epel-release-5-4.noarch.rpm .
check_sha256sum epel-release-5-4.noarch.rpm $EPEL_RPM_HASH

# Dev toolset (for LLVM and other projects requiring C++11 support)
wget -q http://people.centos.org/tru/devtools-2/devtools-2.repo
check_sha256sum devtools-2.repo $DEVTOOLS_HASH
mv devtools-2.repo /etc/yum.repos.d/devtools-2.repo
rpm -Uvh --replacepkgs epel-release-5*.rpm
rm -f epel-release-5*.rpm

# Setup postgresql repo
sed -r -i 's/\[(base|update)\]/[\1]\nexclude=postgresql*\n/g' /etc/yum.repos.d/CentOS-Base.repo
wget --no-check-certificate https://download.postgresql.org/pub/repos/yum/9.5/redhat/rhel-5-x86_64/pgdg-centos95-9.5-3.noarch.rpm
rpm -Uvh --replacepkgs pgdg-centos*.rpm
rm -f pgdg-centos*.rpm
yum list postgres*
# from now on, we shall only use curl to retrieve files
yum -y erase wget

# Development tools and libraries
yum -y install \
automake \
bison \
bzip2 \
cmake28 \
devtoolset-2-binutils \
devtoolset-2-gcc \
devtoolset-2-gcc-c++ \
devtoolset-2-gcc-gfortran \
diffutils \
expat-devel \
gettext \
kernel-devel-`uname -r` \
file \
make \
patch \
unzip \
which \
yasm \
${PYTHON_COMPILE_DEPS}

# Build an OpenSSL for both curl and the Pythons. We'll delete this at the end.
build_openssl $OPENSSL_ROOT $OPENSSL_HASH

# Install curl so we can have TLS 1.2 in this ancient container.
build_curl $CURL_ROOT $CURL_HASH
hash -r
curl --version
curl-config --features

# Install a git we link against OpenSSL so that we can use TLS 1.2
build_git $GIT_ROOT $GIT_HASH
git version

# Install newest autoconf
build_autoconf $AUTOCONF_ROOT $AUTOCONF_HASH
autoconf --version

# Install newest automake
build_automake $AUTOMAKE_ROOT $AUTOMAKE_HASH
automake --version

# Install newest libtool
build_libtool $LIBTOOL_ROOT $LIBTOOL_HASH
libtool --version

# Install a more recent SQLite3
curl -fsSLO $SQLITE_AUTOCONF_DOWNLOAD_URL/$SQLITE_AUTOCONF_VERSION.tar.gz
check_sha256sum $SQLITE_AUTOCONF_VERSION.tar.gz $SQLITE_AUTOCONF_HASH
tar xfz $SQLITE_AUTOCONF_VERSION.tar.gz
cd $SQLITE_AUTOCONF_VERSION
do_standard_install
cd ..
rm -rf $SQLITE_AUTOCONF_VERSION*

# Compile the latest Python releases.
# (In order to have a proper SSL module, Python is compiled
# against a recent openssl [see env vars above], which is linked
# statically.
mkdir -p /opt/python
build_cpythons $CPYTHON_VERSIONS

PY36_BIN=/opt/python/cp36-cp36m/bin

# Install certifi and auditwheel
$PY36_BIN/pip install --require-hashes -r $MY_DIR/py36-requirements.txt

# Our openssl doesn't know how to find the system CA trust store
#   (https://github.com/pypa/manylinux/issues/53)
# And it's not clear how up-to-date that is anyway
# So let's just use the same one pip and everyone uses
ln -s $($PY36_BIN/python -c 'import certifi; print(certifi.where())') \
/opt/_internal/certs.pem
# If you modify this line you also have to modify the versions in the
# Dockerfiles:
export SSL_CERT_FILE=/opt/_internal/certs.pem

# Install patchelf (latest with unreleased bug fixes)
curl -fsSL -o patchelf.tar.gz https://github.com/NixOS/patchelf/archive/$PATCHELF_VERSION.tar.gz
check_sha256sum patchelf.tar.gz $PATCHELF_HASH
tar -xzf patchelf.tar.gz
(cd patchelf-$PATCHELF_VERSION && ./bootstrap.sh && do_standard_install)
rm -rf patchelf.tar.gz patchelf-$PATCHELF_VERSION

# Build/install latest libxml, libxsl, and libxmlsec1
curl -fsSLO http://xmlsoft.org/sources/libxml2-2.9.4.tar.gz
curl -fsSLO http://xmlsoft.org/sources/libxslt-1.1.29.tar.gz
curl -fsSL -o xmlsec-1_2_24.tar.gz https://github.com/lsh123/xmlsec/archive/xmlsec-1_2_24.tar.gz
echo 'ae249165c173b1ff386ee8ad676815f5  libxml2-2.9.4.tar.gz' > md5sums
echo 'a129d3c44c022de3b9dcf6d6f288d72e  libxslt-1.1.29.tar.gz' >> md5sums
echo 'bdb38e4d18fb49f991c3e7586a561c5a  xmlsec-1_2_24.tar.gz' >> md5sums
md5sum -c md5sums
tar -xzf libxml2-2.9.4.tar.gz
tar -xzf libxslt-1.1.29.tar.gz
tar -xzf xmlsec-1_2_24.tar.gz
(cd libxml2-2.9.4 && sed -i "/seems to be moved/s/^/#/" ltmain.sh && ./configure --prefix=/usr --with-history --with-python=$PY36_BIN/python && make && make install)
(cd libxslt-1.1.29 && sed -i "/seems to be moved/s/^/#/" ltmain.sh && ./configure --prefix=/usr --with-history && make && make install)
(export ACLOCAL_PATH=/usr/share/aclocal && cd xmlsec-xmlsec-1_2_24 && ./autogen.sh --prefix=/usr && make && make install)

ln -s $PY36_BIN/auditwheel /usr/local/bin/auditwheel

# Clean up development headers and other unnecessary stuff for
# final image
yum -y erase \
avahi \
bitstream-vera-fonts \
freetype \
gtk2 \
hicolor-icon-theme \
libX11 \
wireless-tools  > /dev/null 2>&1
yum -y install ${MANYLINUX1_DEPS}
yum -y clean all > /dev/null 2>&1
yum list installed

# we don't need libpython*.a, and they're many megabytes
find /opt/_internal -name '*.a' -print0 | xargs -0 rm -f

# Strip what we can -- and ignore errors, because this just attempts to strip
# *everything*, including non-ELF files:
find /opt/_internal -type f -print0 \
| xargs -0 -n1 strip --strip-unneeded 2>/dev/null || true

# We do not need the Python test suites, or indeed the precompiled .pyc and
# .pyo files. Partially cribbed from:
#    https://github.com/docker-library/python/blob/master/3.4/slim/Dockerfile
find /opt/_internal -depth \
\( -type d -a -name test -o -name tests \) \
-o \( -type f -a -name '*.pyc' -o -name '*.pyo' \) | xargs rm -rf

for PYTHON in /opt/python/*/bin/python; do
    # Smoke test to make sure that our Pythons work, and do indeed detect as
    # being manylinux compatible:
    $PYTHON $MY_DIR/manylinux1-check.py
    # Make sure that SSL cert checking works
    $PYTHON $MY_DIR/ssl-check.py
done

# Fix libc headers to remain compatible with C99 compilers.
find /usr/include/ -type f -exec sed -i 's/\bextern _*inline_*\b/extern __inline __attribute__ ((__gnu_inline__))/g' {} +
