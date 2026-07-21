#include "petrunner/core.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cwctype>
#include <fstream>
#include <random>
#include <stdexcept>
#include <unordered_set>

#include <nlohmann/json.hpp>
#include <webp/decode.h>
#include <windows.h>
#include <wincodec.h>

namespace petrunner {
namespace {
constexpr double kVelocityRetention = .18;
constexpr double kRestitution = .72;

std::string utf8(const std::filesystem::path& value) { return value.string(); }
std::string lower(std::string value) { std::ranges::transform(value, value.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); }); return value; }
bool contained(const std::filesystem::path& child, const std::filesystem::path& parent) {
  auto relative = child.lexically_relative(parent);
  return !relative.empty() && !relative.is_absolute() && *relative.begin() != "..";
}
std::string nonempty(const nlohmann::json& value, const char* key) {
  if (!value.contains(key) || !value[key].is_string()) return {};
  auto text = value[key].get<std::string>();
  const auto first = text.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  return text.substr(first, text.find_last_not_of(" \t\r\n") - first + 1);
}

void decode_png(const std::filesystem::path& path, int& width, int& height, std::vector<std::uint8_t>& pixels) {
  IWICImagingFactory* factory = nullptr;
  IWICBitmapDecoder* decoder = nullptr;
  IWICBitmapFrameDecode* frame = nullptr;
  IWICFormatConverter* converter = nullptr;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))) ||
      FAILED(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) || FAILED(factory->CreateFormatConverter(&converter))) {
    if (converter) converter->Release(); if (frame) frame->Release(); if (decoder) decoder->Release(); if (factory) factory->Release();
    throw std::runtime_error("spritesheet cannot be decoded");
  }
  UINT w {}, h {};
  frame->GetSize(&w, &h);
  if (FAILED(converter->Initialize(frame, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) {
    converter->Release(); frame->Release(); decoder->Release(); factory->Release(); throw std::runtime_error("spritesheet cannot be decoded");
  }
  width = static_cast<int>(w); height = static_cast<int>(h); pixels.resize(static_cast<size_t>(w) * h * 4);
  const auto result = converter->CopyPixels(nullptr, w * 4, static_cast<UINT>(pixels.size()), pixels.data());
  converter->Release(); frame->Release(); decoder->Release(); factory->Release();
  if (FAILED(result)) throw std::runtime_error("spritesheet cannot be decoded");
}
void decode_webp(const std::filesystem::path& path, int& width, int& height, std::vector<std::uint8_t>& pixels) {
  std::ifstream file(path, std::ios::binary);
  std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(file)), {});
  if (bytes.empty() || !WebPGetInfo(bytes.data(), bytes.size(), &width, &height)) throw std::runtime_error("spritesheet cannot be decoded");
  std::vector<std::uint8_t> rgba(static_cast<size_t>(width) * height * 4);
  if (!WebPDecodeRGBAInto(bytes.data(), bytes.size(), rgba.data(), rgba.size(), width * 4)) throw std::runtime_error("spritesheet cannot be decoded");
  pixels.resize(rgba.size());
  for (size_t i = 0; i < rgba.size(); i += 4) {
    const auto alpha = rgba[i + 3];
    pixels[i] = static_cast<std::uint8_t>((rgba[i + 2] * alpha) / 255); pixels[i + 1] = static_cast<std::uint8_t>((rgba[i + 1] * alpha) / 255);
    pixels[i + 2] = static_cast<std::uint8_t>((rgba[i] * alpha) / 255); pixels[i + 3] = alpha;
  }
}
} // namespace

Size atlas_size(SpriteVersion version) { return version == SpriteVersion::v2 ? Size { 1536, 2288 } : Size { 1536, 1872 }; }
Size atlas_cell_size(SpriteVersion) { return { 192, 208 }; }
int animation_row(AnimationState state) { return static_cast<int>(state); }
std::vector<double> frame_durations(AnimationState state) {
  switch (state) {
    case AnimationState::idle: return { .84, .33, .33, .42, .42, .96 };
    case AnimationState::running_right: case AnimationState::running_left: return { .12, .12, .12, .12, .12, .12, .22, .22 };
    case AnimationState::waving: return { .14, .14, .14, .28 };
    case AnimationState::jumping: return { .14, .14, .14, .14, .28 };
    case AnimationState::failed: return { .14, .14, .14, .14, .14, .14, .14, .24 };
    case AnimationState::waiting: return { .15, .15, .15, .15, .15, .26 };
    case AnimationState::running: return { .12, .12, .12, .12, .12, .22 };
    case AnimationState::review: return { .15, .15, .15, .15, .15, .28 };
  }
  return {};
}
std::optional<int> cycles_before_idle(AnimationState state) { if (state == AnimationState::waving) return 2; if (state == AnimationState::jumping) return 3; if (state == AnimationState::failed) return 1; return std::nullopt; }

Rect clamp_rect(Rect value, Size size, Rect bounds) {
  value.x = std::clamp(value.x, bounds.x, bounds.x + bounds.width - size.width);
  value.y = std::clamp(value.y, bounds.y, bounds.y + bounds.height - size.height); return value;
}
bool step_physics(MotionState& motion, Size pet_size, Rect bounds, double elapsed) {
  const auto dt = std::clamp(elapsed, 0., 1.); if (!dt) return false;
  motion.position.x += motion.velocity.x * dt; motion.position.y += motion.velocity.y * dt;
  const auto max_x = std::max(bounds.x, bounds.x + bounds.width - pet_size.width); const auto max_y = std::max(bounds.y, bounds.y + bounds.height - pet_size.height);
  bool bounced = false;
  if (motion.position.x < bounds.x) { motion.position.x = bounds.x; motion.velocity.x = std::abs(motion.velocity.x) * kRestitution; bounced = true; }
  else if (motion.position.x > max_x) { motion.position.x = max_x; motion.velocity.x = -std::abs(motion.velocity.x) * kRestitution; bounced = true; }
  if (motion.position.y < bounds.y) { motion.position.y = bounds.y; motion.velocity.y = std::abs(motion.velocity.y) * kRestitution; bounced = true; }
  else if (motion.position.y > max_y) { motion.position.y = max_y; motion.velocity.y = -std::abs(motion.velocity.y) * kRestitution; bounced = true; }
  const auto retention = std::pow(kVelocityRetention, dt); motion.velocity.x *= retention; motion.velocity.y *= retention;
  if (std::hypot(motion.velocity.x, motion.velocity.y) < 8) motion.velocity = {};
  return bounced;
}
void AnimationPlayback::start(AnimationState state) { state_ = state; frame_index_ = completed_cycles_ = 0; elapsed_in_frame_ = 0; if (state == AnimationState::idle) idle_action_index_ = 0; }
void AnimationPlayback::advance(double elapsed) {
  elapsed_in_frame_ += elapsed; auto durations = frame_durations(state_);
  while (elapsed_in_frame_ >= durations[frame_index_]) { elapsed_in_frame_ -= durations[frame_index_]; ++frame_index_; if (frame_index_ == static_cast<int>(durations.size())) { frame_index_ = 0; ++completed_cycles_; if (auto limit = cycles_before_idle(state_); limit && completed_cycles_ >= *limit) { start(AnimationState::idle); return; } } }
}
std::optional<AutonomyConfiguration> AutonomyConfiguration::create(double minimum, double maximum, std::vector<AutonomousAction> actions) { if (minimum < 5 || maximum > 30 || minimum > maximum || actions.empty()) return std::nullopt; return AutonomyConfiguration { minimum, maximum, std::move(actions) }; }
AutonomyPolicy::AutonomyPolicy(AutonomyConfiguration configuration, std::function<double()> random) : configuration_(std::move(configuration)), random_(std::move(random)) { if (!random_) random_ = [] { static thread_local std::mt19937 engine { std::random_device{}() }; return std::generate_canonical<double, 53>(engine); }; }
void AutonomyPolicy::update(AutonomyConfiguration configuration) { configuration_ = std::move(configuration); due_at_ = 0; }
void AutonomyPolicy::reset(double now) { due_at_ = now + configuration_.minimum_wait + (configuration_.maximum_wait - configuration_.minimum_wait) * random_(); }
std::optional<AutonomousAction> AutonomyPolicy::next(double now) { if (!due_at_) reset(now); if (now < due_at_) return std::nullopt; const auto index = std::min(static_cast<size_t>(random_() * configuration_.enabled_actions.size()), configuration_.enabled_actions.size() - 1); reset(now); return configuration_.enabled_actions[index]; }

SpriteAtlas SpriteAtlas::load(const std::filesystem::path& path, SpriteVersion version) {
  SpriteAtlas atlas; const auto extension = lower(path.extension().string()); if (extension == ".png") decode_png(path, atlas.width_, atlas.height_, atlas.pixels_); else if (extension == ".webp") decode_webp(path, atlas.width_, atlas.height_, atlas.pixels_); else throw std::runtime_error("spritesheet extension is unsupported");
  const auto expected = atlas_size(version); if (atlas.width_ != expected.width || atlas.height_ != expected.height) throw std::runtime_error("atlas dimensions are invalid"); return atlas;
}
PetDescriptor load_pet_package(const std::filesystem::path& input) {
  const auto package = std::filesystem::weakly_canonical(input); const auto manifest_path = package / "pet.json"; if (!std::filesystem::is_regular_file(manifest_path)) throw std::runtime_error("pet.json is missing");
  nlohmann::json manifest; try { std::ifstream stream(manifest_path); stream >> manifest; } catch (...) { throw std::runtime_error("pet.json is invalid"); }
  const auto raw_version = manifest.value("spriteVersionNumber", 1); if (raw_version != 1 && raw_version != 2) throw std::runtime_error("spriteVersionNumber is unsupported"); const auto version = static_cast<SpriteVersion>(raw_version);
  auto relative = nonempty(manifest, "spritesheetPath"); if (relative.empty()) relative = "spritesheet.webp"; const auto sheet = std::filesystem::weakly_canonical(package / std::filesystem::u8path(relative)); if (!contained(sheet, package)) throw std::runtime_error("spritesheetPath escapes the pet directory"); if (!std::filesystem::is_regular_file(sheet)) throw std::runtime_error("spritesheet file is missing");
  SpriteAtlas::load(sheet, version); auto id = nonempty(manifest, "id"); if (id.empty()) id = utf8(package.filename()); auto name = nonempty(manifest, "displayName"); if (name.empty()) name = id; return { id, name, nonempty(manifest, "description"), version, package, sheet };
}
PetScanResult load_pet_directory(const std::filesystem::path& directory) {
  PetScanResult result; if (!std::filesystem::is_directory(directory)) { result.failures.push_back({ utf8(directory.filename()), "pets directory is missing" }); return result; }
  std::unordered_set<std::string> ids; for (const auto& entry : std::filesystem::directory_iterator(directory)) if (entry.is_directory()) try { auto pet = load_pet_package(entry.path()); if (!ids.insert(lower(pet.id)).second) throw std::runtime_error("duplicate pet id"); result.pets.push_back(std::move(pet)); } catch (const std::exception& error) { result.failures.push_back({ utf8(entry.path().filename()), error.what() }); }
  std::ranges::sort(result.pets, {}, [](const PetDescriptor& pet) { return lower(pet.id); }); return result;
}
std::filesystem::path default_pets_directory() { const auto home = std::getenv("CODEX_HOME"); if (home && *home) return std::filesystem::u8path(home) / "pets"; wchar_t* profile {}; size_t size {}; _wdupenv_s(&profile, &size, L"USERPROFILE"); std::filesystem::path path = profile ? std::filesystem::path(profile) : std::filesystem::current_path(); free(profile); return path / ".codex" / "pets"; }
} // namespace petrunner
