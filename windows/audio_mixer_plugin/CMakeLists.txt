cmake_minimum_required(VERSION 3.14)
project(audio_mixer_plugin)

# ---------------------------------------------------------------------------
# Require C++17 globally for this sub-project.
# ---------------------------------------------------------------------------
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---------------------------------------------------------------------------
# Shared library (DLL on Windows)
# ---------------------------------------------------------------------------
add_library(audio_mixer_plugin SHARED
    audio_mixer.cpp
)

# Export all symbols that are declared extern "C" in the DLL.
# On MSVC the symbols are exported via __declspec(dllexport) which miniaudio
# handles automatically when MINIAUDIO_IMPLEMENTATION is defined in a SHARED
# build.  We additionally set the standard Windows DLL export definition.
target_compile_definitions(audio_mixer_plugin PRIVATE
    AUDIO_MIXER_PLUGIN_EXPORTS
    # Suppress MSVC min/max macro conflicts with <algorithm>
    NOMINMAX
    WIN32_LEAN_AND_MEAN
)

# Suppress C4819 (file encoding) and C4244 (uint64→uint32 narrowing in miniaudio)
if(MSVC)
    target_compile_options(audio_mixer_plugin PRIVATE /wd4819 /wd4244)
endif()

# ---------------------------------------------------------------------------
# Include directories
# ---------------------------------------------------------------------------
# The plugin directory contains both audio_mixer.h and miniaudio.h
# (miniaudio.h must be downloaded separately — see the TODO at the top of
# audio_mixer.cpp).
target_include_directories(audio_mixer_plugin PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

# ---------------------------------------------------------------------------
# Windows system libraries required by miniaudio
# ---------------------------------------------------------------------------
target_link_libraries(audio_mixer_plugin PRIVATE
    ole32      # COM initialisation used by some miniaudio backends
    winmm      # Windows Multimedia API (waveOut fallback)
)

# ---------------------------------------------------------------------------
# Install the DLL next to the Flutter runner executable so that it can be
# found at runtime without modifying PATH.
#
# 重要: DESTINATION は相対パス "." を使う。`${CMAKE_INSTALL_PREFIX}` を
# 直接埋め込むと、`add_subdirectory(audio_mixer_plugin)` 時点の値(デフォルト
# `C:/Program Files/<project>`)が固定されてしまい、親プロジェクトが後から
# 設定する build/windows/Release/ にファイルが届かず、管理者権限が必要な
# パスへの書き込みで失敗する。相対パスにすれば install 実行時の最終的な
# CMAKE_INSTALL_PREFIX が使われる。
# ---------------------------------------------------------------------------
install(TARGETS audio_mixer_plugin
    RUNTIME DESTINATION "."
    COMPONENT Runtime
)
