#include "petrunner/core.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <stdexcept>

using namespace petrunner;

namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
void animation_contract() {
  check(frame_durations(AnimationState::idle) == std::vector<double> { .84, .33, .33, .42, .42, .96 }, "idle timing changed");
  AnimationPlayback playback; playback.start(AnimationState::jumping); playback.advance(1.12);
  check(playback.state() == AnimationState::jumping, "jump must retain its configured cycles"); playback.advance(1.12);
  check(playback.state() == AnimationState::jumping, "jump must retain its configured cycles"); playback.advance(1.12);
  check(playback.state() == AnimationState::idle, "jump must return to idle after three cycles");
}
void autonomy_contract() {
  check(!AutonomyConfiguration::create(4, 20, { AutonomousAction::walk }), "minimum wait must be validated");
  check(!AutonomyConfiguration::create(10, 31, { AutonomousAction::walk }), "maximum wait must be validated");
  const auto configuration = *AutonomyConfiguration::create(10, 10, { AutonomousAction::cry });
  AutonomyPolicy policy(configuration, [] { return 0.; }); policy.reset(2);
  check(!policy.next(11), "action must wait until due"); check(policy.next(12) == AutonomousAction::cry, "configured action must be selected");
}
void physics_contract() {
  MotionState motion { { 90, 80 }, { 100, 100 } }; const bool bounced = step_physics(motion, { 10, 10 }, { 0, 0, 100, 100 }, .2);
  check(bounced && motion.velocity.x < 0 && motion.velocity.y < 0, "edge collision must bounce");
  const auto clamped = clamp_rect({ -2, 300, 0, 0 }, { 10, 10 }, { 0, 0, 100, 100 }); check(clamped.x == 0 && clamped.y == 90, "position must clamp to working area");
}
void atlas_contract() { check(atlas_size(SpriteVersion::v2).width == 1536 && atlas_size(SpriteVersion::v2).height == 2288, "v2 atlas dimensions changed"); check(atlas_size(SpriteVersion::v1).height == 1872 && atlas_cell_size(SpriteVersion::v1).width == 192, "v1 atlas contract changed"); }
} // namespace

int main() {
  try { animation_contract(); autonomy_contract(); physics_contract(); atlas_contract(); std::cout << "native core tests passed\n"; return EXIT_SUCCESS; }
  catch (const std::exception& error) { std::cerr << error.what() << '\n'; return EXIT_FAILURE; }
}
