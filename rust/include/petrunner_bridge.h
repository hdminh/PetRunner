#ifndef PETRUNNER_BRIDGE_H
#define PETRUNNER_BRIDGE_H

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#define PETRUNNER_OK 0

#define PETRUNNER_INVALID_ARGUMENT 1

#define PETRUNNER_INVALID_HANDLE 2

#define PETRUNNER_OPERATION_FAILED 3

#define PETRUNNER_PANIC 4

typedef struct AnimationHandle AnimationHandle;

typedef struct AtlasHandle AtlasHandle;

typedef struct MonitorStoreHandle MonitorStoreHandle;

typedef struct PetrunnerBuffer {
  uint8_t *data;
  uintptr_t len;
} PetrunnerBuffer;

typedef struct PetrunnerAnimationSnapshot {
  int32_t state;
  int32_t frame_index;
  double elapsed_in_frame;
  int32_t row;
  int32_t column;
} PetrunnerAnimationSnapshot;

typedef struct PetrunnerAtlasAddress {
  int32_t row;
  int32_t column;
} PetrunnerAtlasAddress;

typedef struct PetrunnerMotionState {
  double x;
  double y;
  double velocity_x;
  double velocity_y;
} PetrunnerMotionState;

typedef struct PetrunnerSize {
  double width;
  double height;
} PetrunnerSize;

typedef struct PetrunnerRect {
  double x;
  double y;
  double width;
  double height;
} PetrunnerRect;

typedef struct PetrunnerPhysicsResult {
  bool horizontal_bounce;
  bool vertical_bounce;
} PetrunnerPhysicsResult;

int32_t petrunner_bridge_version(struct PetrunnerBuffer *output);

/**
 * Scans a pet library without ever modifying its contents. The returned UTF-8 JSON is a
 * `PetScanResult` object and is owned by Rust until `petrunner_buffer_free` is called.
 */
int32_t petrunner_scan_pets(const char *path, struct PetrunnerBuffer *output);

int32_t petrunner_monitor_store_create(struct MonitorStoreHandle **output);

void petrunner_monitor_store_destroy(struct MonitorStoreHandle *handle);

int32_t petrunner_monitor_store_upsert_json(struct MonitorStoreHandle *handle,
                                            const uint8_t *event_json,
                                            uintptr_t event_json_len);

int32_t petrunner_monitor_store_select_previous(struct MonitorStoreHandle *handle);

int32_t petrunner_monitor_store_select_next(struct MonitorStoreHandle *handle);

int32_t petrunner_monitor_store_remove_json(struct MonitorStoreHandle *handle,
                                            const uint8_t *key_json,
                                            uintptr_t key_json_len);

int32_t petrunner_monitor_store_set_display_name_json(struct MonitorStoreHandle *handle,
                                                      const uint8_t *update_json,
                                                      uintptr_t update_json_len);

int32_t petrunner_monitor_store_clear(struct MonitorStoreHandle *handle);

int32_t petrunner_monitor_store_snapshot_json(const struct MonitorStoreHandle *handle,
                                              struct PetrunnerBuffer *output);

int32_t petrunner_monitor_decode_envelope_json(const uint8_t *data,
                                               uintptr_t len,
                                               const char *token,
                                               struct PetrunnerBuffer *output);

int32_t petrunner_monitor_normalize_json(const char *provider,
                                         const uint8_t *payload,
                                         uintptr_t payload_len,
                                         const char *event_name,
                                         struct PetrunnerBuffer *output);

int32_t petrunner_provider_detect_json(const uint8_t *paths_json,
                                       uintptr_t paths_json_len,
                                       struct PetrunnerBuffer *output);

int32_t petrunner_provider_config_install_json(const char *provider,
                                               const uint8_t *data,
                                               uintptr_t len,
                                               const char *executable_path,
                                               struct PetrunnerBuffer *output);

int32_t petrunner_provider_config_remove_json(const char *provider,
                                              const uint8_t *data,
                                              uintptr_t len,
                                              struct PetrunnerBuffer *output);

int32_t petrunner_provider_hooks_install(const char *home,
                                         const uint8_t *providers_json,
                                         uintptr_t providers_json_len,
                                         const char *executable_path);

int32_t petrunner_provider_hooks_remove_all(const char *home);

int32_t petrunner_cursor_title_json(const char *database_path,
                                    const char *conversation_id,
                                    struct PetrunnerBuffer *output);

void petrunner_buffer_free(struct PetrunnerBuffer buffer);

int32_t petrunner_atlas_create(const char *path, int32_t version, struct AtlasHandle **output);

void petrunner_atlas_destroy(struct AtlasHandle *handle);

int32_t petrunner_atlas_frame_png(const struct AtlasHandle *handle,
                                  int32_t row,
                                  int32_t column,
                                  struct PetrunnerBuffer *output);

int32_t petrunner_animation_create(int32_t initial_state, struct AnimationHandle **output);

int32_t petrunner_animation_frame_count(int32_t state);

double petrunner_animation_frame_duration(int32_t state, int32_t index);

int32_t petrunner_animation_cycles_before_idle(int32_t state);

void petrunner_animation_destroy(struct AnimationHandle *handle);

int32_t petrunner_animation_start(struct AnimationHandle *handle, int32_t state);

int32_t petrunner_animation_advance(struct AnimationHandle *handle, double delta_time);

int32_t petrunner_animation_snapshot(const struct AnimationHandle *handle,
                                     struct PetrunnerAnimationSnapshot *output);

bool petrunner_look_direction(double dx,
                              double dy,
                              double deadzone,
                              struct PetrunnerAtlasAddress *output);

int32_t petrunner_physics_step(struct PetrunnerMotionState *motion,
                               struct PetrunnerSize size,
                               struct PetrunnerRect bounds,
                               double retention,
                               double restitution,
                               double stop_speed,
                               double maximum_delta_time,
                               double delta_time,
                               struct PetrunnerPhysicsResult *output);

int32_t petrunner_physics_clamp(double origin_x,
                                double origin_y,
                                struct PetrunnerSize size,
                                struct PetrunnerRect bounds,
                                struct PetrunnerMotionState *output);

#endif  /* PETRUNNER_BRIDGE_H */
