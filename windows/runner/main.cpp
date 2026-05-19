#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

Win32Window::Point CenterOnPrimaryMonitor(const Win32Window::Size& size) {
  const POINT primary_point{0, 0};
  HMONITOR monitor =
      MonitorFromPoint(primary_point, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  GetMonitorInfoW(monitor, &monitor_info);

  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const double scale_factor = dpi / 96.0;

  const LONG work_width =
      monitor_info.rcWork.right - monitor_info.rcWork.left;
  const LONG work_height =
      monitor_info.rcWork.bottom - monitor_info.rcWork.top;
  const LONG window_width = static_cast<LONG>(size.width * scale_factor);
  const LONG window_height = static_cast<LONG>(size.height * scale_factor);

  const LONG origin_x =
      monitor_info.rcWork.left + (work_width - window_width) / 2;
  const LONG origin_y =
      monitor_info.rcWork.top + (work_height - window_height) / 2;

  return Win32Window::Point(
      static_cast<unsigned int>(origin_x / scale_factor),
      static_cast<unsigned int>(origin_y / scale_factor));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Size size(960, 720);
  Win32Window::Point origin = CenterOnPrimaryMonitor(size);
  if (!window.Create(L"SSTerm", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
