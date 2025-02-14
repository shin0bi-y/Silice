#!/bin/bash

git submodule init
git submodule update

mkdir BUILD
cd BUILD

mkdir build-silicedgb
cd build-silicedgb

cmake -DCMAKE_BUILD_TYPE=Release -G "Unix Makefiles" ../../tools/silice-debugger
make install

cd ..

cd ..
