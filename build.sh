rm -rf build && mkdir build && cd build
#source /opt/rh/devtoolset-11/enable
export CC=clang-15
export CXX=clang++-15
cmake .. -DCMAKE_BUILD_TYPE=debug 
nohup ninja 2>&1 > ~/ckbuild.log &
