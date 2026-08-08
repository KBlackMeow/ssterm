# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(flutter_pty_library VERSION 0.0.1 LANGUAGES C)

add_library(flutter_pty SHARED
  "flutter_pty.c"
)

set_target_properties(flutter_pty PROPERTIES
  PUBLIC_HEADER flutter_pty.h
  OUTPUT_NAME "flutter_pty"
)

target_compile_definitions(flutter_pty PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size.
  target_link_options(flutter_pty PRIVATE "-Wl,-z,max-page-size=16384")
endif()

if (WIN32)
  # Source files are UTF-8; otherwise MSVC decodes comments/string literals
  # through the active ANSI code page and emits C4819 on Chinese Windows.
  target_compile_options(flutter_pty PRIVATE /utf-8)
  # Owns the Job Object for non-PTY background commands. Keeping this as a
  # small native process lets it create the real shell suspended, associate it
  # with a Job Object, then resume it with no process-tree escape window.
  add_executable(flutter_pty_job_runner "flutter_pty_job_runner_win.c")
  target_compile_options(flutter_pty_job_runner PRIVATE /utf-8)
endif()
