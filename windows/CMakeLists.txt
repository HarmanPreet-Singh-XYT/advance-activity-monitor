cmake_minimum_required(VERSION 3.14)

project(device_activity_monitor VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Source files ───────────────────────────────────────────────────────
set(PLUGIN_SOURCES
  "device_activity_monitor_plugin.cpp"
  "device_activity_monitor_plugin_c_api.cpp"
)

# ── Build as shared library (Flutter plugin convention) ────────────────
add_library(device_activity_monitor SHARED
  ${PLUGIN_SOURCES}
)

# Symbols not explicitly exported are hidden
set_target_properties(device_activity_monitor PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)

# ── Include directories ────────────────────────────────────────────────
target_include_directories(device_activity_monitor PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
)

target_include_directories(device_activity_monitor PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)

# ── Flutter dependency (injected by Flutter tooling) ──────────────────
target_include_directories(device_activity_monitor PRIVATE
  ${FLUTTER_MANAGED_DIR}
)

# ── Windows system libraries ───────────────────────────────────────────
target_link_libraries(device_activity_monitor PRIVATE
  flutter
  flutter_wrapper_plugin
  # XInput — controller state polling
  XInput.lib
  # SetupAPI + HID — HID device enumeration and I/O
  setupapi.lib
  hid.lib
  # MMDevice + EndpointVolume — audio peak meter (COM)
  # Linked via #pragma comment in the .cpp; listed here for clarity
  # and to satisfy any generator that ignores pragmas (e.g. Ninja + Clang)
  Ole32.lib
  # Power notifications (RegisterSuspendResumeNotification)
  PowrProf.lib
  # GDI (not used by this plugin, but avoids linker complaints from
  # any Flutter wrapper that pulls it in transitively)
  gdi32.lib
)

# ── Compile definitions ────────────────────────────────────────────────
target_compile_definitions(device_activity_monitor PRIVATE
  # Suppress min/max macros from <windows.h>
  NOMINMAX
  # Trim rarely-used Windows headers
  WIN32_LEAN_AND_MEAN
  # Target Windows 10 and above (required for
  # RegisterSuspendResumeNotification and modern COM)
  _WIN32_WINNT=0x0A00
  WINVER=0x0A00
  # Unicode
  UNICODE
  _UNICODE
  # Plugin DLL export macro used by the C API header
  FLUTTER_PLUGIN_IMPL
)

# ── Warnings ───────────────────────────────────────────────────────────
target_compile_options(device_activity_monitor PRIVATE
  /W3
  /WX-          # Warnings are not errors (Flutter plugins ship with W3 by convention)
  /wd4100       # Unreferenced formal parameter — common in Flutter method stubs
  /wd4996       # Deprecated POSIX names
  /EHsc         # Standard C++ exception handling
  # SEH (__try/__except) requires /EHa in some configs; we use /EHsc + __try
  # which is valid for MSVC as long as we don't mix C++ exceptions and SEH
  # in the same function (which we do not).
)

# ── Install (Flutter tooling copies the DLL automatically via this) ────
set(device_activity_monitor_bundled_libraries
  "$<TARGET_FILE:device_activity_monitor>"
  PARENT_SCOPE
)