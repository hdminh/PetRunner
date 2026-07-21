#include "petrunner/core.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include <d2d1.h>
#include <nlohmann/json.hpp>
#include <shellapi.h>
#include <windows.h>

using namespace petrunner;
namespace {
constexpr UINT kTrayMessage = WM_APP + 10;
constexpr UINT_PTR kFrameTimer = 1;
constexpr int kCommandPet = 1000, kCommandSize = 2000, kCommandToggleAutonomy = 3000, kCommandReset = 3001, kCommandSettings = 3002, kCommandReload = 3003, kCommandQuit = 3004;

std::wstring wide(const std::string& text) { if (text.empty()) return {}; const auto size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0); std::wstring output(size, 0); MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, output.data(), size); output.pop_back(); return output; }

struct Settings {
  std::string selected_id;
  double width { 112 };
  std::optional<double> left, top;
  bool autonomy_enabled { true };
  double autonomy_minimum_wait { 10 }, autonomy_maximum_wait { 20 };
  std::vector<AutonomousAction> enabled_actions { AutonomousAction::walk, AutonomousAction::wave, AutonomousAction::jump, AutonomousAction::cry };
};

std::filesystem::path settings_path() {
  wchar_t* local {}; size_t size {}; _wdupenv_s(&local, &size, L"LOCALAPPDATA"); auto path = std::filesystem::path(local ? local : L".") / L"PetRunner" / L"settings.json"; free(local); return path;
}
Settings load_settings() {
  Settings result; try { std::ifstream file(settings_path()); nlohmann::json json; file >> json; if (json.contains("SelectedPetId") && json["SelectedPetId"].is_string()) result.selected_id = json["SelectedPetId"].get<std::string>(); result.width = json.value("Width", 112.); if (json.contains("Left") && !json["Left"].is_null()) result.left = json["Left"].get<double>(); if (json.contains("Top") && !json["Top"].is_null()) result.top = json["Top"].get<double>(); result.autonomy_enabled = json.value("AutonomyEnabled", true); result.autonomy_minimum_wait = json.value("AutonomyMinimumWait", 10.); result.autonomy_maximum_wait = json.value("AutonomyMaximumWait", 20.); if (json.contains("EnabledAutonomousActions")) { result.enabled_actions.clear(); for (const auto& action : json["EnabledAutonomousActions"]) if (action.is_number_integer() && action.get<int>() >= 0 && action.get<int>() <= 3) result.enabled_actions.push_back(static_cast<AutonomousAction>(action.get<int>())); } } catch (...) {} return result;
}
void save_settings(const Settings& settings) {
  std::filesystem::create_directories(settings_path().parent_path()); nlohmann::json json { { "SelectedPetId", settings.selected_id }, { "Width", settings.width }, { "Left", settings.left ? nlohmann::json(*settings.left) : nlohmann::json(nullptr) }, { "Top", settings.top ? nlohmann::json(*settings.top) : nlohmann::json(nullptr) }, { "AutonomyEnabled", settings.autonomy_enabled }, { "AutonomyMinimumWait", settings.autonomy_minimum_wait }, { "AutonomyMaximumWait", settings.autonomy_maximum_wait } }; json["EnabledAutonomousActions"] = nlohmann::json::array(); for (const auto action : settings.enabled_actions) json["EnabledAutonomousActions"].push_back(static_cast<int>(action)); std::ofstream file(settings_path()); file << json.dump();
}

class App {
 public:
  App(HINSTANCE instance, std::filesystem::path pets_path) : instance_(instance), pets_path_(std::move(pets_path)), settings_(load_settings()) {}
  int run();
 private:
  HINSTANCE instance_ {}; std::filesystem::path pets_path_; HWND controller_ {}, overlay_ {}, settings_window_ {}; NOTIFYICONDATAW icon_ {};
  std::vector<PetDescriptor> pets_; std::vector<PetFailure> failures_; std::optional<PetDescriptor> pet_; std::optional<SpriteAtlas> atlas_; Settings settings_; AnimationPlayback playback_; AutonomyPolicy autonomy_; std::optional<MotionState> motion_;
  int width_ { 112 }, height_ { 121 }; HBITMAP dib_ {}; void* dib_bits_ {}; SIZE dib_size_ {}; POINT drag_start_ {}, window_start_ {}; bool dragging_ {}, resizing_ {}; double velocity_x_ {}, velocity_y_ {}; std::chrono::steady_clock::time_point previous_tick_ = std::chrono::steady_clock::now();
  static LRESULT CALLBACK controller_proc(HWND, UINT, WPARAM, LPARAM); static LRESULT CALLBACK overlay_proc(HWND, UINT, WPARAM, LPARAM); static LRESULT CALLBACK settings_proc(HWND, UINT, WPARAM, LPARAM);
  void reload(); void show_pet(const PetDescriptor&, bool restore); void resize(double); void render(); void tick(); void show_menu(); void update_icon(); void save_position(); void reset_position(); Rect working_area() const; void create_settings_window(); void apply_settings_window();
};

LRESULT CALLBACK App::controller_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* app = reinterpret_cast<App*>(GetWindowLongPtr(window, GWLP_USERDATA)); if (message == WM_NCCREATE) { app = static_cast<App*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams); SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app)); }
  if (!app) return DefWindowProc(window, message, wparam, lparam);
  if (message == kTrayMessage && lparam == WM_RBUTTONUP) { app->show_menu(); return 0; }
  if (message == WM_COMMAND) {
    const auto id = LOWORD(wparam);
    if (id >= kCommandPet && id < kCommandSize) { const auto index = id - kCommandPet; if (index < static_cast<int>(app->pets_.size())) app->show_pet(app->pets_[index], false); }
    else if (id >= kCommandSize && id < kCommandToggleAutonomy) app->resize((id - kCommandSize) * 16. + 80.);
    else if (id == kCommandToggleAutonomy) { app->settings_.autonomy_enabled = !app->settings_.autonomy_enabled; save_settings(app->settings_); }
    else if (id == kCommandReset) app->reset_position(); else if (id == kCommandSettings) app->create_settings_window(); else if (id == kCommandReload) app->reload(); else if (id == kCommandQuit) PostQuitMessage(0); return 0;
  }
  if (message == WM_DESTROY) { Shell_NotifyIconW(NIM_DELETE, &app->icon_); return 0; }
  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT CALLBACK App::overlay_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* app = reinterpret_cast<App*>(GetWindowLongPtr(window, GWLP_USERDATA)); if (message == WM_NCCREATE) { app = static_cast<App*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams); SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app)); }
  if (!app) return DefWindowProc(window, message, wparam, lparam);
  switch (message) {
    case WM_TIMER: app->tick(); return 0;
    case WM_LBUTTONDOWN: { POINT pointer {}; GetCursorPos(&pointer); RECT rect {}; GetWindowRect(window, &rect); app->drag_start_ = pointer; app->window_start_ = { rect.left, rect.top }; app->resizing_ = LOWORD(lparam) >= app->width_ - 18 && HIWORD(lparam) >= app->height_ - 18; app->dragging_ = true; app->motion_.reset(); SetCapture(window); return 0; }
    case WM_MOUSEMOVE: if (app->dragging_) { POINT pointer {}; GetCursorPos(&pointer); const auto dx = pointer.x - app->drag_start_.x, dy = pointer.y - app->drag_start_.y; if (app->resizing_) app->resize(app->width_ + dx); else { SetWindowPos(window, HWND_TOPMOST, app->window_start_.x + dx, app->window_start_.y + dy, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE); app->velocity_x_ = dx * 12.; app->velocity_y_ = dy * 12.; } app->render(); } return 0;
    case WM_LBUTTONUP: if (app->dragging_) { ReleaseCapture(); app->dragging_ = false; if (!app->resizing_) { RECT rect {}; GetWindowRect(window, &rect); app->motion_ = MotionState { { static_cast<double>(rect.left), static_cast<double>(rect.top) }, { app->velocity_x_, app->velocity_y_ } }; } app->save_position(); } return 0;
    case WM_DISPLAYCHANGE: app->reset_position(); return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT CALLBACK App::settings_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* app = reinterpret_cast<App*>(GetWindowLongPtr(window, GWLP_USERDATA)); if (message == WM_NCCREATE) { app = static_cast<App*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams); SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app)); }
  if (!app) return DefWindowProc(window, message, wparam, lparam); if (message == WM_COMMAND && LOWORD(wparam) == IDOK) { app->apply_settings_window(); DestroyWindow(window); return 0; } if (message == WM_COMMAND && LOWORD(wparam) == IDCANCEL) { DestroyWindow(window); return 0; } if (message == WM_DESTROY) app->settings_window_ = {}; return DefWindowProc(window, message, wparam, lparam);
}

Rect App::working_area() const { HMONITOR monitor = MonitorFromWindow(overlay_, MONITOR_DEFAULTTONEAREST); MONITORINFO info { sizeof(info) }; GetMonitorInfo(monitor, &info); const auto& area = info.rcWork; return { static_cast<double>(area.left), static_cast<double>(area.top), static_cast<double>(area.right - area.left), static_cast<double>(area.bottom - area.top) }; }
void App::resize(double requested) { width_ = static_cast<int>(std::clamp(requested, 80., 224.)); height_ = static_cast<int>(width_ * 208. / 192.); SetWindowPos(overlay_, HWND_TOPMOST, 0, 0, width_, height_, SWP_NOMOVE | SWP_NOACTIVATE); settings_.width = width_; save_settings(settings_); }
void App::save_position() { RECT rect {}; GetWindowRect(overlay_, &rect); settings_.left = rect.left; settings_.top = rect.top; save_settings(settings_); }
void App::reset_position() { const auto area = working_area(); SetWindowPos(overlay_, HWND_TOPMOST, static_cast<int>(area.x + area.width - width_ - 32), static_cast<int>(area.y + area.height - height_ - 32), 0, 0, SWP_NOSIZE | SWP_NOACTIVATE); save_position(); }
void App::show_pet(const PetDescriptor& descriptor, bool restore) { try { atlas_ = SpriteAtlas::load(descriptor.spritesheet_path, descriptor.version); pet_ = descriptor; playback_.start(AnimationState::idle); resize(settings_.width); if (restore && settings_.left && settings_.top) SetWindowPos(overlay_, HWND_TOPMOST, static_cast<int>(*settings_.left), static_cast<int>(*settings_.top), 0, 0, SWP_NOSIZE | SWP_NOACTIVATE); else reset_position(); settings_.selected_id = descriptor.id; save_settings(settings_); ShowWindow(overlay_, SW_SHOWNOACTIVATE); render(); } catch (const std::exception& error) { failures_.push_back({ descriptor.id, error.what() }); ShowWindow(overlay_, SW_HIDE); } }
void App::reload() { const auto scan = load_pet_directory(pets_path_.empty() ? default_pets_directory() : pets_path_); pets_ = scan.pets; failures_ = scan.failures; auto found = std::ranges::find_if(pets_, [&](const auto& candidate) { return candidate.id == settings_.selected_id; }); if (found == pets_.end() && !pets_.empty()) found = pets_.begin(); if (found == pets_.end()) ShowWindow(overlay_, SW_HIDE); else show_pet(*found, true); }
void App::tick() { const auto now = std::chrono::steady_clock::now(); const auto elapsed = std::chrono::duration<double>(now - previous_tick_).count(); previous_tick_ = now; playback_.advance(elapsed); if (motion_) { RECT rect {}; GetWindowRect(overlay_, &rect); motion_->position = { static_cast<double>(rect.left), static_cast<double>(rect.top) }; step_physics(*motion_, { static_cast<double>(width_), static_cast<double>(height_) }, working_area(), elapsed); SetWindowPos(overlay_, HWND_TOPMOST, static_cast<int>(motion_->position.x), static_cast<int>(motion_->position.y), 0, 0, SWP_NOSIZE | SWP_NOACTIVATE); if (std::hypot(motion_->velocity.x, motion_->velocity.y) == 0) { motion_.reset(); save_position(); } }
  if (settings_.autonomy_enabled && !dragging_ && !motion_) if (const auto action = autonomy_.next(std::chrono::duration<double>(now.time_since_epoch()).count())) { switch (*action) { case AutonomousAction::walk: playback_.start(AnimationState::running_right); break; case AutonomousAction::wave: playback_.start(AnimationState::waving); break; case AutonomousAction::jump: playback_.start(AnimationState::jumping); break; case AutonomousAction::cry: playback_.start(AnimationState::failed); break; } } render(); }
void App::render() { if (!atlas_ || !IsWindowVisible(overlay_)) return; if (dib_size_.cx != width_ || dib_size_.cy != height_) { if (dib_) DeleteObject(dib_); HDC screen = GetDC(nullptr); BITMAPINFO info {}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER); info.bmiHeader.biWidth = width_; info.bmiHeader.biHeight = -height_; info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB; dib_ = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &dib_bits_, nullptr, 0); ReleaseDC(nullptr, screen); dib_size_ = { width_, height_ }; }
  auto* target = static_cast<std::uint8_t*>(dib_bits_); const auto address = playback_.address(); const auto source_size = atlas_cell_size(pet_->version); const auto& source = atlas_->pixels(); for (int y = 0; y < height_; ++y) for (int x = 0; x < width_; ++x) { const auto sx = std::min(source_size.width - 1, std::floor(x * source_size.width / width_)); const auto sy = std::min(source_size.height - 1, std::floor(y * source_size.height / height_)); const auto offset = (static_cast<size_t>(address.row * source_size.height + sy) * atlas_->width() + address.column * source_size.width + sx) * 4; std::memcpy(target + (static_cast<size_t>(y) * width_ + x) * 4, source.data() + offset, 4); }
  HDC screen = GetDC(nullptr), memory = CreateCompatibleDC(screen); auto previous = SelectObject(memory, dib_); POINT source_point {}; SIZE size { width_, height_ }; POINT position {}; RECT rect {}; GetWindowRect(overlay_, &rect); position = { rect.left, rect.top }; BLENDFUNCTION blend { AC_SRC_OVER, 0, 255, AC_SRC_ALPHA }; UpdateLayeredWindow(overlay_, screen, &position, &size, memory, &source_point, 0, &blend, ULW_ALPHA); SelectObject(memory, previous); DeleteDC(memory); ReleaseDC(nullptr, screen); }
void App::show_menu() { HMENU menu = CreatePopupMenu(), pets = CreatePopupMenu(), sizes = CreatePopupMenu(); for (size_t i = 0; i < pets_.size(); ++i) AppendMenuW(pets, MF_STRING | (pet_ && pets_[i].id == pet_->id ? MF_CHECKED : 0), kCommandPet + static_cast<UINT>(i), wide(pets_[i].display_name).c_str()); for (int width = 80; width <= 224; width += 16) AppendMenuW(sizes, MF_STRING | (width == width_ ? MF_CHECKED : 0), kCommandSize + (width - 80) / 16, (std::to_wstring(width) + L" px").c_str()); AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(pets), L"Change Pet"); AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(sizes), L"Size"); AppendMenuW(menu, MF_STRING | (settings_.autonomy_enabled ? MF_CHECKED : 0), kCommandToggleAutonomy, L"Autonomous Pet"); AppendMenuW(menu, MF_STRING, kCommandReset, L"Reset Position"); AppendMenuW(menu, MF_STRING, kCommandSettings, L"Settings..."); AppendMenuW(menu, MF_SEPARATOR, 0, nullptr); AppendMenuW(menu, MF_STRING, kCommandReload, L"Reload Pets"); AppendMenuW(menu, MF_STRING, kCommandQuit, L"Quit PetRunner"); POINT point {}; GetCursorPos(&point); SetForegroundWindow(controller_); TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, 0, controller_, nullptr); DestroyMenu(menu); }
void App::update_icon() { icon_.cbSize = sizeof(icon_); icon_.hWnd = controller_; icon_.uID = 1; icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP; icon_.uCallbackMessage = kTrayMessage; icon_.hIcon = LoadIcon(nullptr, IDI_APPLICATION); wcscpy_s(icon_.szTip, L"PetRunner"); Shell_NotifyIconW(NIM_ADD, &icon_); }
void App::create_settings_window() { if (settings_window_) { ShowWindow(settings_window_, SW_SHOWNORMAL); SetForegroundWindow(settings_window_); return; } settings_window_ = CreateWindowExW(WS_EX_DLGMODALFRAME, L"PetRunnerSettings", L"PetRunner Settings", WS_CAPTION | WS_SYSMENU | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT, 330, 260, controller_, nullptr, instance_, this); CreateWindowW(L"STATIC", L"Wait between actions", WS_CHILD | WS_VISIBLE, 20, 20, 180, 20, settings_window_, nullptr, instance_, nullptr); HWND minimum = CreateWindowW(L"COMBOBOX", L"", WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST, 20, 45, 90, 150, settings_window_, reinterpret_cast<HMENU>(10), instance_, nullptr); HWND maximum = CreateWindowW(L"COMBOBOX", L"", WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST, 130, 45, 90, 150, settings_window_, reinterpret_cast<HMENU>(11), instance_, nullptr); for (int second = 5; second <= 30; ++second) { const auto value = std::to_wstring(second); SendMessageW(minimum, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(value.c_str())); SendMessageW(maximum, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(value.c_str())); } SendMessageW(minimum, CB_SETCURSEL, static_cast<WPARAM>(settings_.autonomy_minimum_wait - 5), 0); SendMessageW(maximum, CB_SETCURSEL, static_cast<WPARAM>(settings_.autonomy_maximum_wait - 5), 0); const wchar_t* names[] { L"Walk", L"Wave", L"Jump", L"Cry" }; for (int i = 0; i < 4; ++i) { auto box = CreateWindowW(L"BUTTON", names[i], WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 20, 85 + i * 24, 120, 22, settings_window_, reinterpret_cast<HMENU>(20 + i), instance_, nullptr); SendMessageW(box, BM_SETCHECK, std::ranges::find(settings_.enabled_actions, static_cast<AutonomousAction>(i)) != settings_.enabled_actions.end() ? BST_CHECKED : BST_UNCHECKED, 0); } CreateWindowW(L"BUTTON", L"Save", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON, 150, 190, 70, 28, settings_window_, reinterpret_cast<HMENU>(IDOK), instance_, nullptr); CreateWindowW(L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE, 230, 190, 70, 28, settings_window_, reinterpret_cast<HMENU>(IDCANCEL), instance_, nullptr); }
void App::apply_settings_window() { const auto minimum = static_cast<double>(SendMessageW(GetDlgItem(settings_window_, 10), CB_GETCURSEL, 0, 0) + 5), maximum = static_cast<double>(SendMessageW(GetDlgItem(settings_window_, 11), CB_GETCURSEL, 0, 0) + 5); std::vector<AutonomousAction> actions; for (int i = 0; i < 4; ++i) if (SendMessageW(GetDlgItem(settings_window_, 20 + i), BM_GETCHECK, 0, 0) == BST_CHECKED) actions.push_back(static_cast<AutonomousAction>(i)); if (const auto configuration = AutonomyConfiguration::create(minimum, maximum, actions)) { settings_.autonomy_minimum_wait = configuration->minimum_wait; settings_.autonomy_maximum_wait = configuration->maximum_wait; settings_.enabled_actions = configuration->enabled_actions; autonomy_.update(*configuration); save_settings(settings_); } else MessageBoxW(settings_window_, L"Choose at least one action and a valid wait range.", L"PetRunner Settings", MB_OK | MB_ICONWARNING); }
int App::run() { WNDCLASSW controller { .lpfnWndProc = controller_proc, .hInstance = instance_, .lpszClassName = L"PetRunnerController" }; WNDCLASSW overlay { .lpfnWndProc = overlay_proc, .hInstance = instance_, .lpszClassName = L"PetRunnerOverlay", .hCursor = LoadCursor(nullptr, IDC_HAND) }; WNDCLASSW settings { .lpfnWndProc = settings_proc, .hInstance = instance_, .lpszClassName = L"PetRunnerSettings" }; RegisterClassW(&controller); RegisterClassW(&overlay); RegisterClassW(&settings); controller_ = CreateWindowW(L"PetRunnerController", L"PetRunner", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance_, this); overlay_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE, L"PetRunnerOverlay", L"PetRunner", WS_POPUP, 0, 0, width_, height_, nullptr, nullptr, instance_, this); SetTimer(overlay_, kFrameTimer, 16, nullptr); update_icon(); reload(); MSG message {}; while (GetMessageW(&message, nullptr, 0, 0) > 0) { TranslateMessage(&message); DispatchMessageW(&message); } if (dib_) DeleteObject(dib_); return static_cast<int>(message.wParam); }
} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  std::filesystem::path pets;
  int count {};
  auto arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  for (int index = 1; arguments && index + 1 < count; ++index) if (std::wstring_view(arguments[index]) == L"--pets-dir") { pets = arguments[index + 1]; break; }
  LocalFree(arguments);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); App app(instance, std::move(pets)); const auto code = app.run(); CoUninitialize(); return code;
}
