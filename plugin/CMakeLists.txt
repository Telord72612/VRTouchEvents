cmake_minimum_required(VERSION 3.21)

project(VRTouchEvents LANGUAGES CXX VERSION 1.0.0)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# CommonLibSSE-NG (VR-enabled) as a local subdirectory.
# Point this at your own CommonLibVR checkout, e.g.
#   cmake --preset vr -DCOMMONLIB_PATH="C:/dev/CommonLibVR-4.14.0"
# Built against CommonLibVR 4.14.0.
set(COMMONLIB_PATH "../../CommonLibVR" CACHE PATH "Path to CommonLibSSE-NG (VR) source")

# VR-only runtime — this plugin is VR-exclusive.
set(ENABLE_SKYRIM_SE OFF CACHE BOOL "" FORCE)
set(ENABLE_SKYRIM_AE OFF CACHE BOOL "" FORCE)
set(ENABLE_SKYRIM_VR ON  CACHE BOOL "" FORCE)
set(BUILD_TESTS      OFF CACHE BOOL "" FORCE)

add_subdirectory("${COMMONLIB_PATH}" CommonLibSSE EXCLUDE_FROM_ALL)

# --- The plugin DLL: PPB touch-API bridge + TESHitEvent sink + SKSE shell ---
# CBPCHook.cpp is still compiled in, but only for its TESHitEvent sink (the
# combat gate).  Its cbp.dll trampolines are no longer installed as of V3.0 —
# see the note in main.cpp.
add_library(VRTouchEvents SHARED
    src/main.cpp
    src/CBPCHook.cpp
    src/PpbBridge.cpp
)

target_precompile_headers(VRTouchEvents PRIVATE src/PCH.h)

target_link_libraries(VRTouchEvents PRIVATE CommonLibSSE::CommonLibSSE)

set_target_properties(VRTouchEvents PROPERTIES
    OUTPUT_NAME "VRTouchEvents"
    DEBUG_POSTFIX ""
)

# Optional: drop the built DLL straight into your mod folder's SKSE/Plugins.
# Set it for your own install, e.g.
#   cmake --preset vr -DMOD_OUTPUT="D:/MO2/mods/VRTouchEvents V3.0/SKSE/Plugins"
# Leave it empty to skip the copy and just take the DLL out of build/vr/Release.
#
# ⚠ The copy step FAILS SILENTLY if Skyrim is running (Windows locks the loaded
# DLL) and its error message does not contain the word "error" — always verify
# with an md5 on both paths before assuming a new build is deployed.
set(MOD_OUTPUT "" CACHE PATH "Optional: mod SKSE/Plugins folder to copy the DLL into")
if(MOD_OUTPUT)
    add_custom_command(TARGET VRTouchEvents POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "${MOD_OUTPUT}"
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:VRTouchEvents>" "${MOD_OUTPUT}/"
        COMMENT "Copying VRTouchEvents.dll to mod folder"
    )
endif()
