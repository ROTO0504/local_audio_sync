cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "audio_mixer_ffi")
project(${PROJECT_NAME} LANGUAGES CXX)

# CMake 3.31+ の install() DESTINATION 正規化警告を抑止。
if(POLICY CMP0177)
  cmake_policy(SET CMP0177 NEW)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---------------------------------------------------------------------------
# Shared library (DLL)。ターゲット名は Dart 側のロード名
# (audio_mixer_plugin.dll)と一致させること。
# ---------------------------------------------------------------------------
add_library(audio_mixer_plugin SHARED
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/audio_mixer.cpp"
)

target_compile_definitions(audio_mixer_plugin PRIVATE
    AUDIO_MIXER_PLUGIN_EXPORTS
    # Suppress MSVC min/max macro conflicts with <algorithm>
    NOMINMAX
    WIN32_LEAN_AND_MEAN
)

if(MSVC)
    # miniaudio.h は約 9 万行のシングルヘッダで、MINIAUDIO_IMPLEMENTATION を
    # 展開すると Debug ビルドで PDB のモジュール上限(LNK1140)を踏む。
    # 対策として、デバッグ情報を PDB ではなく obj ファイル内に埋め込む(/Z7)。
    target_compile_options(audio_mixer_plugin PRIVATE
        /wd4819 /wd4244
        $<$<CONFIG:Debug>:/Z7>
    )
    target_link_options(audio_mixer_plugin PRIVATE
        $<$<CONFIG:Debug>:/DEBUG:NONE>
    )
endif()

target_include_directories(audio_mixer_plugin PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../src"
)

# Windows system libraries required by miniaudio
target_link_libraries(audio_mixer_plugin PRIVATE
    ole32      # COM initialisation used by some miniaudio backends
    winmm      # Windows Multimedia API (waveOut fallback)
)

# ---------------------------------------------------------------------------
# flutter run(Debug)は build/windows/x64/runner/Debug/ から exe を起動する
# ため、ビルド直後から Runner と同じディレクトリに DLL が並ぶよう出力先を
# 構成ごとに上書きする(旧 windows/audio_mixer_plugin の対策を踏襲)。
# CMAKE_BINARY_DIR はトップレベルのビルドディレクトリを指す。
# ---------------------------------------------------------------------------
set_target_properties(audio_mixer_plugin PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY_DEBUG   "${CMAKE_BINARY_DIR}/runner/Debug"
    RUNTIME_OUTPUT_DIRECTORY_PROFILE "${CMAKE_BINARY_DIR}/runner/Profile"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/runner/Release"
)

# Flutter の標準プラグイン機構(generated_plugins.cmake)がこの変数を
# PLUGIN_BUNDLED_LIBRARIES に追加し、Release バンドルへ install する。
set(audio_mixer_ffi_bundled_libraries
  $<TARGET_FILE:audio_mixer_plugin>
  PARENT_SCOPE
)
