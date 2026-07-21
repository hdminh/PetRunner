#pragma once

#include <array>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace petrunner {

struct Size { double width {}; double height {}; };
struct Point { double x {}; double y {}; };
struct Rect { double x {}; double y {}; double width {}; double height {}; };

enum class SpriteVersion { v1 = 1, v2 = 2 };
enum class AnimationState { idle, running_right, running_left, waving, jumping, failed, waiting, running, review };
enum class AutonomousAction { walk, wave, jump, cry };

struct AtlasAddress { int row {}; int column {}; };
struct PetDescriptor {
  std::string id;
  std::string display_name;
  std::string description;
  SpriteVersion version { SpriteVersion::v1 };
  std::filesystem::path package_path;
  std::filesystem::path spritesheet_path;
};
struct PetFailure { std::string id; std::string message; };
struct PetScanResult { std::vector<PetDescriptor> pets; std::vector<PetFailure> failures; };
struct MotionState { Point position; Point velocity; };
struct AutonomyConfiguration {
  double minimum_wait { 10 };
  double maximum_wait { 20 };
  std::vector<AutonomousAction> enabled_actions { AutonomousAction::walk, AutonomousAction::wave, AutonomousAction::jump, AutonomousAction::cry };
  static std::optional<AutonomyConfiguration> create(double minimum, double maximum, std::vector<AutonomousAction> actions);
};

Size atlas_size(SpriteVersion version);
Size atlas_cell_size(SpriteVersion version);
std::vector<double> frame_durations(AnimationState state);
int animation_row(AnimationState state);
std::optional<int> cycles_before_idle(AnimationState state);
Rect clamp_rect(Rect value, Size size, Rect bounds);
bool step_physics(MotionState& motion, Size pet_size, Rect bounds, double elapsed);

class AnimationPlayback {
 public:
  void start(AnimationState state);
  void advance(double elapsed);
  [[nodiscard]] AnimationState state() const { return state_; }
  [[nodiscard]] AtlasAddress address() const { return { animation_row(state_), frame_index_ }; }
 private:
  AnimationState state_ { AnimationState::idle };
  int frame_index_ {};
  int completed_cycles_ {};
  double elapsed_in_frame_ {};
  int idle_action_index_ {};
};

class AutonomyPolicy {
 public:
  explicit AutonomyPolicy(AutonomyConfiguration configuration = {}, std::function<double()> random = {});
  void update(AutonomyConfiguration configuration);
  void reset(double now);
  std::optional<AutonomousAction> next(double now);
 private:
  AutonomyConfiguration configuration_;
  std::function<double()> random_;
  double due_at_ {};
};

class SpriteAtlas {
 public:
  static SpriteAtlas load(const std::filesystem::path& path, SpriteVersion version);
  [[nodiscard]] int width() const { return width_; }
  [[nodiscard]] int height() const { return height_; }
  [[nodiscard]] const std::vector<std::uint8_t>& pixels() const { return pixels_; }
 private:
  int width_ {};
  int height_ {};
  std::vector<std::uint8_t> pixels_; // premultiplied BGRA
};

PetDescriptor load_pet_package(const std::filesystem::path& package);
PetScanResult load_pet_directory(const std::filesystem::path& directory);
std::filesystem::path default_pets_directory();

} // namespace petrunner
