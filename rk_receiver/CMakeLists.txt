cmake_minimum_required(VERSION 3.16)
project(rknn_plate_v5_cpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(OpenCV REQUIRED)
find_package(Threads REQUIRED)
find_package(X11 REQUIRED)

set(RKNN_API_ROOT "" CACHE PATH "RKNN SDK root directory")
find_path(RKNN_API_INCLUDE_DIR
    NAMES rknn_api.h
    HINTS ${RKNN_API_ROOT} ENV RKNN_API_ROOT
    PATH_SUFFIXES include include/rknn rknpu2/include runtime/Linux/librknn_api/include)
find_library(RKNN_API_LIBRARY
    NAMES rknnrt librknnrt
    HINTS ${RKNN_API_ROOT} ENV RKNN_API_ROOT
    PATH_SUFFIXES lib lib64 runtime/Linux/librknn_api/aarch64 runtime/Linux/librknn_api/Linux)

if (NOT RKNN_API_INCLUDE_DIR OR NOT RKNN_API_LIBRARY)
    message(FATAL_ERROR "未找到 RKNN SDK，请设置 RKNN_API_ROOT 或手动指定 RKNN_API_INCLUDE_DIR / RKNN_API_LIBRARY")
endif()

add_executable(main_v5_cpp
    main_v4.cpp
    plate_bitmap_font.cpp
    plate_postprocess.cpp
    rknn_runtime.cpp)

if (TARGET X11::X11)
    set(MAIN_V4_X11_LINK_LIB X11::X11)
else()
    set(MAIN_V4_X11_LINK_LIB ${X11_X11_LIB})
endif()

if (TARGET X11::Xext)
    set(MAIN_V4_XEXT_LINK_LIB X11::Xext)
else()
    set(MAIN_V4_XEXT_LINK_LIB ${X11_Xext_LIB})
endif()

target_include_directories(main_v5_cpp PRIVATE
    ${OpenCV_INCLUDE_DIRS}
    ${RKNN_API_INCLUDE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${X11_INCLUDE_DIR})

target_link_libraries(main_v5_cpp PRIVATE
    ${OpenCV_LIBS}
    ${RKNN_API_LIBRARY}
    Threads::Threads
    ${MAIN_V4_X11_LINK_LIB}
    ${MAIN_V4_XEXT_LINK_LIB})

if (MSVC)
    target_compile_options(main_v5_cpp PRIVATE /W4 /permissive-)
else()
    target_compile_options(main_v5_cpp PRIVATE -Wall -Wextra -Wpedantic)
endif()
