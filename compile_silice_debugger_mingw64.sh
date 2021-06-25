#!/bin/bash

git submodule init
git submodule update

cd tools/silice-debugger
git submodule init
git submodule update
cd ..
cd ..

mkdir BUILD
cd BUILD

mkdir build-silicedgb
cd build-silicedgb

cmake -DCMAKE_BUILD_TYPE=Release -G "MinGW Makefiles" ../../tools/silice-debugger
mingw32-make install

cd ..

cd ..
