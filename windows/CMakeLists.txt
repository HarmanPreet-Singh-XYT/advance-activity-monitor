cmake_minimum_required(VERSION 3.14)

project(device_activity_monitor_plugin VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Source files ───────────────────────────────────────────────────────
set(PLUGIN_SOURCES
  "device_activity_monitor_plugin.cpp"
  "device_activity_monitor_plugin_c_api.cpp"
)

# ── Build as shared library (Flutter plugin convention) ────────────────
add_library(device_activity_monitor_plugin SHARED
  ${PLUGIN_SOURCES}
)

# Symbols not explicitly exported are hidden
set_target_properties(device_activity_monitor_plugin PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)

# ── Include directories ────────────────────────────────────────────────
target_include_directories(device_activity_monitor_plugin PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
)

target_include_directories(device_activity_monitor_plugin PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)

# ── Flutter dependency (injected by Flutter tooling) ──────────────────
target_include_directories(device_activity_monitor_plugin PRIVATE
  ${FLUTTER_MANAGED_DIR}
)

# ── Windows system libraries ───────────────────────────────────────────
target_link_libraries(device_activity_monitor_plugin PRIVATE
  flutter
  flutter_wrapper_plugin
  XInput.lib
  setupapi.lib
  hid.lib
  Ole32.lib
  PowrProf.lib
  gdi32.lib
)

# ── Compile definitions ────────────────────────────────────────────────
target_compile_definitions(device_activity_monitor_plugin PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  _WIN32_WINNT=0x0A00
  WINVER=0x0A00
  UNICODE
  _UNICODE
  FLUTTER_PLUGIN_IMPL
)

# ── Warnings ───────────────────────────────────────────────────────────
target_compile_options(device_activity_monitor_plugin PRIVATE
  /W3
  /WX-
  /wd4100
  /wd4996
  /EHsc
)

# ── Install (Flutter tooling copies the DLL automatically via this) ────
set(device_activity_monitor_plugin_bundled_libraries
  "$<TARGET_FILE:device_activity_monitor_plugin>"
  PARENT_SCOPE
)