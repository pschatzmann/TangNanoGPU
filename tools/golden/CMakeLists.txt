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

# Optional: TinyH264 checkout, for the video golden test (decodes
# clips/test_320x240.264). Skipped if not found.
set(TINYH264_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../TinyH264" CACHE PATH "TinyH264 source directory")

add_executable(golden golden.cpp)
target_include_directories(golden PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/shim
    ${TINYGPU_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../../src)
if(EXISTS ${TINYH264_DIR}/src/TinyH264Decoder.h)
  target_include_directories(golden PRIVATE ${TINYH264_DIR}/src)
  target_compile_definitions(golden PRIVATE GOLDEN_CLIP="${CMAKE_CURRENT_SOURCE_DIR}/clips/test_320x240.264")
endif()
if(EXISTS ${TINYMD_DIR}/src/TinyMaterialDesign.h)
  target_include_directories(golden PRIVATE ${TINYMD_DIR}/src)
endif()
target_compile_options(golden PRIVATE -Wall -Wextra -Wno-unused-parameter)
