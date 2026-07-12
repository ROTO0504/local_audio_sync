# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(local_audio_sync LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "local_audio_sync")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# CMake 3.31 以降の install() DESTINATION パス正規化警告(CMP0177)を抑止する。
# Flutter Windows テンプレートが相対パスで install() を呼ぶため警告が大量に出るが、
# NEW 挙動でも実害はないので明示的に新挙動を選ぶ。
if(POLICY CMP0177)
  cmake_policy(SET CMP0177 NEW)
endif()

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# NOTE: audio_mixer は packages/audio_mixer_ffi の FFI プラグインに移設した。
# generated_plugins.cmake が自動で add_subdirectory しビルド・バンドルする。

# opus_flutter_windows is Dart-only on Windows. Flutter's CMake generator still
# calls add_subdirectory on its windows/ path and generated_plugin_registrant.cc
# does  #include <opus_flutter_windows/none.h>.
# We create a minimal stub that satisfies both the CMake subdirectory requirement
# and the header include.
set(_OPUS_WIN
  "${CMAKE_CURRENT_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/opus_flutter_windows")
if(EXISTS "${_OPUS_WIN}" AND NOT EXISTS "${_OPUS_WIN}/windows/CMakeLists.txt")
  # Header: provides the declaration that generated_plugin_registrant.cc includes
  file(MAKE_DIRECTORY "${_OPUS_WIN}/windows/include/opus_flutter_windows")
  file(WRITE "${_OPUS_WIN}/windows/include/opus_flutter_windows/none.h"
    "#pragma once\n"
    "#ifdef __cplusplus\nextern \"C\" {\n#endif\n"
    "void noneRegisterWithRegistrar(void* registrar);\n"
    "#ifdef __cplusplus\n}\n#endif\n")
  # Source: provides the empty implementation
  file(WRITE "${_OPUS_WIN}/windows/stub.cc"
    "extern \"C\" void noneRegisterWithRegistrar(void*) {}\n")
  # CMakeLists: builds the static stub library and exports the include directory
  # so that targets linking against it get the header search path automatically.
  file(WRITE "${_OPUS_WIN}/windows/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.14)\n"
    "project(opus_flutter_windows_windows LANGUAGES CXX)\n"
    "add_library(opus_flutter_windows_plugin STATIC stub.cc)\n"
    "target_include_directories(opus_flutter_windows_plugin PUBLIC include)\n")
endif()
# Always add the stub include directory globally so that
# generated_plugin_registrant.cc can find <opus_flutter_windows/none.h>
# regardless of whether CMake's PRIVATE link propagation is available.
if(EXISTS "${_OPUS_WIN}/windows/include")
  include_directories("${_OPUS_WIN}/windows/include")
endif()

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${CMAKE_CURRENT_BINARY_DIR}/../../native_assets/windows/")
if(EXISTS "${NATIVE_ASSETS_DIR}")
  install(DIRECTORY "${NATIVE_ASSETS_DIR}"
     DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
     COMPONENT Runtime)
endif()

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
set(FLUTTER_ASSETS_PATH "${CMAKE_CURRENT_BINARY_DIR}/../../${FLUTTER_ASSET_DIR_NAME}")
if(EXISTS "${FLUTTER_ASSETS_PATH}")
  install(DIRECTORY "${FLUTTER_ASSETS_PATH}"
    DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)
endif()

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
