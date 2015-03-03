#!/bin/bash

# Copyright 2012, Google Inc. All rights reserved.
# Use of this source code is governed by a BSD-style license that can
# be found in the LICENSE file.

if [ ! -f bootstrap.sh ]; then
  echo "bootstrap.sh must be run from its current directory" 1>&2
  exit 1
fi

if [ "$USER" == "root" ]; then
  echo "Vitess cannot run as root. Please bootstrap with a non-root user."
  exit 1
fi

go version 2>&1 >/dev/null
if [ $? != 0 ]; then
    echo "Go is not installed or is not on \$PATH"
    exit 1
fi

. ./dev.env

mkdir -p $VTROOT/dist
mkdir -p $VTROOT/bin
mkdir -p $VTROOT/lib
mkdir -p $VTROOT/vthook

# install zookeeper
zk_dist=$VTROOT/dist/vt-zookeeper-3.3.5
if [ -d $zk_dist ]; then
  echo "skipping zookeeper build"
else
  (cd $VTTOP/third_party/zookeeper && \
    tar -xjf zookeeper-3.3.5.tbz && \
    mkdir -p $zk_dist/lib && \
    cp zookeeper-3.3.5/contrib/fatjar/zookeeper-3.3.5-fatjar.jar $zk_dist/lib && \
    (cd zookeeper-3.3.5/src/c && \
    ./configure --prefix=$zk_dist && \
    make -j3 install) && rm -rf zookeeper-3.3.5)
  if [ $? -ne 0 ]; then
    echo "zookeeper build failed"
    exit 1
   fi
fi

# install protoc and proto python libraries
protobuf_dist=$VTROOT/dist/protobuf
if [ -d $protobuf_dist ]; then
  echo "skipping protobuf build"
else
  # The directory doesn't exist, so it wasn't picked up by dev.env yet,
  # but the install needs it to exist first, and be in PYTHONPATH.
  export PYTHONPATH=$(prepend_path $PYTHONPATH $protobuf_dist/lib/python2.7/site-packages)
  (mkdir -p $protobuf_dist/lib/python2.7/site-packages && \
    cd $protobuf_dist && \
    wget https://github.com/google/protobuf/archive/v3.0.0-alpha-2.zip && \
    unzip v3.0.0-alpha-2.zip && \
    cd protobuf-3.0.0-alpha-2 && \
    ./autogen.sh && \
    ./configure --prefix=$protobuf_dist && \
    make -j 4 && \
    make install && \
    cd python && \
    python setup.py build --cpp_implementation && \
    python setup.py install --cpp_implementation --prefix=$protobuf_dist)
  if [ $? -ne 0 ]; then
    echo "protobuf build failed"
    exit 1
  fi
fi

# install gRPC C++ base, so we can install the python adapters
grpc_dist=$VTROOT/dist/grpc
if [ -d $grpc_dist ]; then
  echo "skipping gRPC build"
else
  (mkdir -p $grpc_dist && \
    cd $grpc_dist && \
    git clone https://github.com/grpc/grpc.git && \
    cd grpc && \
    git submodule update --init && \
    make && \
    make install prefix=$grpc_dist && \
    cd src/python/src && \
    python setup.py build_ext --include-dirs $grpc_dist/include --library-dirs $grpc_dist/lib && \
    python setup.py install --prefix $grpc_dist)
  if [ $? -ne 0 ]; then
    echo "gRPC build failed"
    exit 1
  fi
fi

ln -nfs $VTTOP/third_party/go/launchpad.net $VTROOT/src
go install launchpad.net/gozk/zookeeper

go get code.google.com/p/goprotobuf/proto
go get golang.org/x/net/context
go get golang.org/x/tools/cmd/goimports
go get github.com/golang/glog
go get github.com/golang/lint/golint
go get github.com/tools/godep
go get google.golang.org/grpc
go get -a github.com/golang/protobuf/protoc-gen-go

# goversion_min returns true if major.minor go version is at least some value.
function goversion_min() {
  [[ "$(go version)" =~ go([0-9]+)\.([0-9]+) ]]
  gotmajor=${BASH_REMATCH[1]}
  gotminor=${BASH_REMATCH[2]}
  [[ "$1" =~ ([0-9]+)\.([0-9]+) ]]
  wantmajor=${BASH_REMATCH[1]}
  wantminor=${BASH_REMATCH[2]}
  [ "$gotmajor" -lt "$wantmajor" ] && return 1
  [ "$gotmajor" -gt "$wantmajor" ] && return 0
  [ "$gotminor" -lt "$wantminor" ] && return 1
  return 0
}

# Packages for uploading code coverage to coveralls.io.
# The cover tool needs to be installed into the Go toolchain, so it will fail
# if Go is installed somewhere that requires root access. However, this tool
# is optional, so we should hide any errors to avoid confusion.
if goversion_min 1.4; then
  go get golang.org/x/tools/cmd/cover &> /dev/null
else
  go get code.google.com/p/go.tools/cmd/cover &> /dev/null
fi
go get github.com/modocache/gover
go get github.com/mattn/goveralls

ln -snf $VTTOP/config $VTROOT/config
ln -snf $VTTOP/data $VTROOT/data
ln -snf $VTTOP/py $VTROOT/py-vtdb
ln -snf $VTTOP/go/zk/zkctl/zksrv.sh $VTROOT/bin/zksrv.sh
ln -snf $VTTOP/test/vthook-test.sh $VTROOT/vthook/test.sh

# install mysql
if [ -z "$MYSQL_FLAVOR" ]; then
  export MYSQL_FLAVOR=MariaDB
fi
case "$MYSQL_FLAVOR" in
  "Mysql56")
    echo "Mysql 5.6 support is under development and not supported yet."
    exit 1
    ;;

  "MariaDB")
    myversion=`$VT_MYSQL_ROOT/bin/mysql --version | grep MariaDB`
    if [ "$myversion" == "" ]; then
      echo "Couldn't find MariaDB in $VT_MYSQL_ROOT. Set VT_MYSQL_ROOT to override search location."
      exit 1
    fi
    echo "Found MariaDB installation in $VT_MYSQL_ROOT."
    ;;

  *)
    echo "Unsupported MYSQL_FLAVOR $MYSQL_FLAVOR"
    exit 1
    ;;

esac

# save the flavor that was used in bootstrap, so it can be restored
# every time dev.env is sourced.
echo "$MYSQL_FLAVOR" > $VTROOT/dist/MYSQL_FLAVOR

# generate pkg-config, so go can use mysql C client
if [ ! -x $VT_MYSQL_ROOT/bin/mysql_config ]; then
  echo "Cannot execute $VT_MYSQL_ROOT/bin/mysql_config. Did you install a client dev package?" 1>&2
  exit 1
fi

cp $VTTOP/config/gomysql.pc.tmpl $VTROOT/lib/gomysql.pc
echo "Version:" "$($VT_MYSQL_ROOT/bin/mysql_config --version)" >> $VTROOT/lib/gomysql.pc
echo "Cflags:" "$($VT_MYSQL_ROOT/bin/mysql_config --cflags) -ggdb -fPIC" >> $VTROOT/lib/gomysql.pc
if [ "$MYSQL_FLAVOR" == "MariaDB" ]; then
  # Use static linking because the shared library doesn't export
  # some internal functions we use, like cli_safe_read.
  echo "Libs:" "$($VT_MYSQL_ROOT/bin/mysql_config --libs_r | sed 's,-lmysqlclient_r,-l:libmysqlclient.a -lstdc++,')" >> $VTROOT/lib/gomysql.pc
else
  echo "Libs:" "$($VT_MYSQL_ROOT/bin/mysql_config --libs_r)" >> $VTROOT/lib/gomysql.pc
fi

# install bson
bson_dist=$VTROOT/dist/py-vt-bson-0.3.2
if [ -d $bson_dist ]; then
  echo "skipping bson python build"
else
  cd $VTTOP/third_party/py/bson-0.3.2 && \
    python ./setup.py install --prefix=$bson_dist && \
    rm -r build
fi

# install cbson
cbson_dist=$VTROOT/dist/py-cbson
if [ -d $cbson_dist ]; then
  echo "skipping cbson python build"
else
  cd $VTTOP/py/cbson && \
    python ./setup.py install --prefix=$cbson_dist
fi

# create pre-commit hooks
echo "creating git pre-commit hooks"
ln -sf $VTTOP/misc/git/pre-commit $VTTOP/.git/hooks/pre-commit

echo
echo "bootstrap finished - run 'source dev.env' in your shell before building."
