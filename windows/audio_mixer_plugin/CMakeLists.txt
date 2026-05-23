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
    # miniaudio.h は約 9 万行のシングルヘッダで、MINIAUDIO_IMPLEMENTATION を
    # 展開すると Debug ビルドで PDB のモジュール上限(LNK1140
    # "too many modules for program database")を踏む。
    # 対策として、デバッグ情報を PDB ではなく obj ファイル内に埋め込む(/Z7)。
    # デバッグ情報自体は保持されるのでブレークポイントは利く。
    target_compile_options(audio_mixer_plugin PRIVATE
        /wd4819 /wd4244
        $<$<CONFIG:Debug>:/Z7>
    )
    target_link_options(audio_mixer_plugin PRIVATE
        $<$<CONFIG:Debug>:/DEBUG:NONE>
    )
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
# ---------------------------------------------------------------------------
install(TARGETS audio_mixer_plugin
    RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
    COMPONENT Runtime
)
