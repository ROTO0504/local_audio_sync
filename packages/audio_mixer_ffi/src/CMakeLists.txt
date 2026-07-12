# Android(NDK)用ビルド定義。android/build.gradle の externalNativeBuild から
# 参照される。Windows は windows/CMakeLists.txt、iOS/macOS は CocoaPods
# (Classes/audio_mixer_ffi.mm)がそれぞれビルドする。
cmake_minimum_required(VERSION 3.18.1)
project(audio_mixer_ffi LANGUAGES CXX)

add_library(audio_mixer_plugin SHARED
    audio_mixer.cpp
)

set_target_properties(audio_mixer_plugin PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
)

target_include_directories(audio_mixer_plugin PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

if(ANDROID)
    # miniaudio は AAudio / OpenSL ES を実行時に dlopen するため、
    # リンクするのは dl / log / m だけでよい。
    target_link_libraries(audio_mixer_plugin dl log m)
endif()
