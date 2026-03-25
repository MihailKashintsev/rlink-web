# This file controls Flutter-level build steps. It should not be edited.
cmake_minimum_required(VERSION 3.13)

set(EPHEMERAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ephemeral")

# Configuration provided via flutter tool.
include(${EPHEMERAL_DIR}/generated_config.cmake)

# TODO: Move the rest of this into files in ephemeral. See
# https://github.com/flutter/flutter/issues/57146.
set(WRAPPER_ROOT "${EPHEMERAL_DIR}/cpp_client_wrapper")

# Set fallback configurations for older versions of the flutter tool.
if (NOT DEFINED FLUTTER_TARGET_PLATFORM)
  set(FLUTTER_TARGET_PLATFORM "linux-x64")
endif()

# === Flutter Library ===
# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(GLIB REQUIRED IMPORTED_TARGET glib-2.0)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)

set(FLUTTER_LIBRARY "${EPHEMERAL_DIR}/libflutter_linux_gtk.so")

# Published to parent scope for the executable target.
set(FLUTTER_LIBRARY ${FLUTTER_LIBRARY} PARENT_SCOPE)
set(FLUTTER_ICU_DATA_FILE "${EPHEMERAL_DIR}/icudtl.dat" PARENT_SCOPE)
set(PROJECT_BUILD_DIR "${PROJECT_DIR}/build/" PARENT_SCOPE)
set(AOT_LIBRARY "${PROJECT_DIR}/build/lib/libapp.so" PARENT_SCOPE)

list(APPEND FLUTTER_LIBRARY_HEADERS
  "fl_basic_message_channel.h"
  "fl_binary_codec.h"
  "fl_binary_messenger.h"
  "fl_dart_project.h"
  "fl_engine.h"
  "fl_json_message_codec.h"
  "fl_json_method_codec.h"
  "fl_message_codec.h"
  "fl_method_call.h"
  "fl_method_channel.h"
  "fl_method_codec.h"
  "fl_method_error_response.h"
  "fl_method_not_implemented_response.h"
  "fl_method_response.h"
  "fl_plugin_registrar.h"
  "fl_plugin_registry.h"
  "fl_standard_message_codec.h"
  "fl_standard_method_codec.h"
  "fl_string_codec.h"
  "fl_texture_registrar.h"
  "fl_value.h"
  "fl_view.h"
  "flutter_linux.h"
)
list(TRANSFORM FLUTTER_LIBRARY_HEADERS PREPEND "${EPHEMERAL_DIR}/")
add_library(flutter INTERFACE)
target_include_directories(flutter INTERFACE
  "${EPHEMERAL_DIR}"
)
target_link_libraries(flutter INTERFACE "${FLUTTER_LIBRARY}")
target_link_libraries(flutter INTERFACE
  PkgConfig::GTK
  PkgConfig::GLIB
  PkgConfig::GIO
)
add_dependencies(flutter flutter_assemble)

# === Flutter tool backend ===
# _phony_ is a non-existent file to ensure this target runs every time,
# since currently FlutterBasePath is not tracked.
add_custom_target(flutter_assemble DEPENDS
  "${FLUTTER_LIBRARY}"
  "${PROJECT_DIR}/.dart_tool/flutter_build/dart_plugin_registrant.dart"
)
add_custom_command(OUTPUT "../${FLUTTER_LIBRARY}" VERBATIM
  COMMAND ${CMAKE_COMMAND} -E env
  ${FLUTTER_TOOL_ENVIRONMENT}
  "${FLUTTER_ROOT}/packages/flutter_tools/bin/tool_backend.sh"
  ${FLUTTER_TARGET_PLATFORM} ${CMAKE_BUILD_TYPE}
  DEPENDS _phony_
)
set_source_files_properties("../${FLUTTER_LIBRARY}" PROPERTIES GENERATED TRUE)
set(GENERATED_PLUGIN_REGISTRANT_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}")

# === Wrapper sources ===
list(APPEND CPP_WRAPPER_SOURCES_CORE
  "core_implementations.cc"
  "plugin_registrar.cc"
  "standard_codec.cc"
  "standard_method_codec.cc"
)
list(TRANSFORM CPP_WRAPPER_SOURCES_CORE PREPEND "${WRAPPER_ROOT}/library_source/")
list(APPEND CPP_WRAPPER_SOURCES_PLUGIN
  "flutter_plugin_registrar.cc"
)
list(TRANSFORM CPP_WRAPPER_SOURCES_PLUGIN PREPEND "${WRAPPER_ROOT}/library_source/")

add_library(flutter_wrapper_app STATIC
  ${CPP_WRAPPER_SOURCES_CORE}
  ${CPP_WRAPPER_SOURCES_PLUGIN}
)
apply_standard_settings(flutter_wrapper_app)
set_target_properties(flutter_wrapper_app PROPERTIES
  POSITION_INDEPENDENT_CODE ON)
target_include_directories(flutter_wrapper_app PUBLIC
  "${WRAPPER_ROOT}/include"
)
target_link_libraries(flutter_wrapper_app PUBLIC flutter)

# === Generated plugin registrant ===
add_library(flutter_plugins STATIC
  "${GENERATED_PLUGIN_REGISTRANT_INCLUDE}/generated_plugin_registrant.cc"
)
apply_standard_settings(flutter_plugins)
set_target_properties(flutter_plugins PROPERTIES
  POSITION_INDEPENDENT_CODE ON)
target_link_libraries(flutter_plugins PUBLIC flutter)
target_include_directories(flutter_plugins PRIVATE
  "${EPHEMERAL_DIR}/include"
)
