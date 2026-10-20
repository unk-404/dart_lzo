cmake_minimum_required(VERSION 3.16)
project(lzo_bench C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Point the harness at liblzo2 2.10.
#
#   -DLZO_ROOT=<prefix>       prefix that contains include/lzo/lzo1x.h and lib/
#                             (e.g. a `cmake --install` prefix)
#   -DLZO_INCLUDE_DIR=<dir>   directory that contains lzo/lzo1x.h
#   -DLZO_LIBRARY=<file>      full path to liblzo2.a / lzo2.lib
#
# With none of them, the usual system locations are searched (Linux:
# `apt install liblzo2-dev`).
set(_lzo_hints "")
if(LZO_ROOT)
  list(APPEND _lzo_hints
    "${LZO_ROOT}/include"
    "${LZO_ROOT}/lib"
    "${LZO_ROOT}/lib/Release"
    "${LZO_ROOT}/Release")
endif()

if(NOT LZO_INCLUDE_DIR)
  find_path(LZO_INCLUDE_DIR NAMES lzo/lzo1x.h HINTS ${_lzo_hints})
endif()
if(NOT LZO_LIBRARY)
  find_library(LZO_LIBRARY NAMES lzo2 liblzo2 HINTS ${_lzo_hints})
endif()

if(NOT LZO_INCLUDE_DIR)
  message(FATAL_ERROR
    "lzo/lzo1x.h not found. Pass -DLZO_INCLUDE_DIR=<dir> or install liblzo2-dev.")
endif()
if(NOT LZO_LIBRARY)
  message(FATAL_ERROR
    "liblzo2 not found. Pass -DLZO_LIBRARY=<file> or install liblzo2-dev.")
endif()
message(STATUS "liblzo2 headers: ${LZO_INCLUDE_DIR}")
message(STATUS "liblzo2 library: ${LZO_LIBRARY}")

add_executable(lzo_bench bench.c)
target_include_directories(lzo_bench PRIVATE "${LZO_INCLUDE_DIR}")
target_link_libraries(lzo_bench PRIVATE "${LZO_LIBRARY}")

if(MSVC)
  target_compile_options(lzo_bench PRIVATE /W4)
else()
  target_compile_options(lzo_bench PRIVATE -Wall -Wextra)
  target_link_libraries(lzo_bench PRIVATE m)
endif()
