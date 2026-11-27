#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <propkey.h>
#include <propsys.h>
#include <propvarutil.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <windows.h>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {
constexpr wchar_t kStellarAppUserModelId[] = L"IWorks.StellarECC";

// Unpackaged desktop apps need a Start Menu shortcut with the same
// AppUserModelID as their toast notifications.
void RegisterStellarToastIdentity() {
  SetCurrentProcessExplicitAppUserModelID(kStellarAppUserModelId);

  PWSTR programs_path = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_CREATE, nullptr,
                                 &programs_path))) {
    return;
  }

  wchar_t executable_path[MAX_PATH] = {};
  const DWORD path_length = GetModuleFileNameW(nullptr, executable_path, MAX_PATH);
  if (path_length == 0 || path_length >= MAX_PATH) {
    CoTaskMemFree(programs_path);
    return;
  }

  std::wstring shortcut_path(programs_path);
  shortcut_path += L"\\Stellar ECC.lnk";
  CoTaskMemFree(programs_path);

  IShellLinkW* shell_link = nullptr;
  HRESULT result = CoCreateInstance(CLSID_ShellLink, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&shell_link));
  if (FAILED(result)) return;

  result = shell_link->SetPath(executable_path);
  if (SUCCEEDED(result)) {
    IPropertyStore* property_store = nullptr;
    result = shell_link->QueryInterface(IID_PPV_ARGS(&property_store));
    if (SUCCEEDED(result)) {
      PROPVARIANT app_id;
      PropVariantInit(&app_id);
      result = InitPropVariantFromString(kStellarAppUserModelId, &app_id);
      if (SUCCEEDED(result)) {
        result = property_store->SetValue(PKEY_AppUserModel_ID, app_id);
        if (SUCCEEDED(result)) result = property_store->Commit();
      }
      PropVariantClear(&app_id);
      property_store->Release();
    }
  }

  if (SUCCEEDED(result)) {
    IPersistFile* persist_file = nullptr;
    result = shell_link->QueryInterface(IID_PPV_ARGS(&persist_file));
    if (SUCCEEDED(result)) {
      persist_file->Save(shortcut_path.c_str(), TRUE);
      persist_file->Release();
    }
  }
  shell_link->Release();
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
  RegisterStellarToastIdentity();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Stellar ECC", origin, size)) {
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
