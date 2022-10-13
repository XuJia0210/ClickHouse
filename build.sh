rm -rf build && mkdir build && cd build
#source /opt/rh/devtoolset-11/enable
export CC=clang
export CXX=clang++
 ~/cmake-3.23.1-linux-x86_64/bin/cmake .. -DCMAKE_BUILD_TYPE=debug 
nohup ninja 2>&1 > ~/ckbuild.log &
