cmake_minimum_required(VERSION 3.14)
project(tangnanogpu_golden LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# TinyGPU checkout (header only). Defaults to a sibling of this library in
# the Arduino libraries folder.
set(TINYGPU_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../TinyGPU" CACHE PATH "TinyGPU source directory")

# Optional: TinyMaterialDesign checkout, for the second (TinyMaterialDesign)
# golden scene. Skipped if not found.
set(TINYMD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../TinyMaterialDesign" CACHE PATH "TinyMaterialDesign source directory")

add_executable(golden golden.cpp)
target_include_directories(golden PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/shim
    ${TINYGPU_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../src)
if(EXISTS ${TINYMD_DIR}/src/TinyMaterialDesign.h)
  target_include_directories(golden PRIVATE ${TINYMD_DIR}/src)
endif()
target_compile_options(golden PRIVATE -Wall -Wextra -Wno-unused-parameter)
