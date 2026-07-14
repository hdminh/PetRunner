#![allow(clippy::missing_safety_doc)]

use std::{
    ffi::{CStr, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
};

use petrunner_core::{
    AgentProvider, AgentSessionStore, AnimationPlayback, AnimationState, Atlas,
    AtlasAddress as CoreAtlasAddress, LookDirection, MotionState as CoreMotionState,
    NormalizedAgentEvent, PhysicsConfig, Rect as CoreRect, Size as CoreSize, SpriteVersion,
    decode_envelope, detect_providers, install_hook_configuration, install_provider_hooks,
    normalize_provider_event, remove_all_provider_hooks, remove_hook_configuration,
    resolve_cursor_title, scan_library,
};

pub const PETRUNNER_OK: i32 = 0;
pub const PETRUNNER_INVALID_ARGUMENT: i32 = 1;
pub const PETRUNNER_INVALID_HANDLE: i32 = 2;
pub const PETRUNNER_OPERATION_FAILED: i32 = 3;
pub const PETRUNNER_PANIC: i32 = 4;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PetrunnerBuffer {
    pub data: *mut u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PetrunnerAnimationSnapshot {
    pub state: i32,
    pub frame_index: i32,
    pub elapsed_in_frame: f64,
    pub row: i32,
    pub column: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PetrunnerPhysicsResult {
    pub horizontal_bounce: bool,
    pub vertical_bounce: bool,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PetrunnerAtlasAddress {
    pub row: i32,
    pub column: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PetrunnerMotionState {
    pub x: f64,
    pub y: f64,
    pub velocity_x: f64,
    pub velocity_y: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PetrunnerSize {
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PetrunnerRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl From<PetrunnerMotionState> for CoreMotionState {
    fn from(value: PetrunnerMotionState) -> Self {
        Self {
            x: value.x,
            y: value.y,
            velocity_x: value.velocity_x,
            velocity_y: value.velocity_y,
        }
    }
}

impl From<CoreMotionState> for PetrunnerMotionState {
    fn from(value: CoreMotionState) -> Self {
        Self {
            x: value.x,
            y: value.y,
            velocity_x: value.velocity_x,
            velocity_y: value.velocity_y,
        }
    }
}

impl From<PetrunnerSize> for CoreSize {
    fn from(value: PetrunnerSize) -> Self {
        Self {
            width: value.width,
            height: value.height,
        }
    }
}

impl From<PetrunnerRect> for CoreRect {
    fn from(value: PetrunnerRect) -> Self {
        Self {
            x: value.x,
            y: value.y,
            width: value.width,
            height: value.height,
        }
    }
}

pub struct AtlasHandle(Atlas);
pub struct AnimationHandle(AnimationPlayback);
pub struct MonitorStoreHandle(AgentSessionStore);

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct DisplayNameUpdate {
    key: petrunner_core::monitor::AgentSessionKey,
    display_name: petrunner_core::DisplayName,
}

fn boundary(action: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(action)).unwrap_or(PETRUNNER_PANIC)
}

unsafe fn required_utf8<'a>(value: *const c_char) -> Result<&'a str, i32> {
    if value.is_null() {
        return Err(PETRUNNER_INVALID_ARGUMENT);
    }
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| PETRUNNER_INVALID_ARGUMENT)
}

unsafe fn required_bytes<'a>(value: *const u8, len: usize) -> Result<&'a [u8], i32> {
    if len == 0 {
        return Ok(&[]);
    }
    if value.is_null() {
        return Err(PETRUNNER_INVALID_ARGUMENT);
    }
    Ok(unsafe { std::slice::from_raw_parts(value.cast::<u8>(), len) })
}

fn provider_from_string(value: &str) -> Result<AgentProvider, i32> {
    serde_json::from_value(serde_json::Value::String(value.to_owned()))
        .map_err(|_| PETRUNNER_INVALID_ARGUMENT)
}

fn json_buffer(value: impl serde::Serialize, output: *mut PetrunnerBuffer) -> i32 {
    match serde_json::to_vec(&value) {
        Ok(json) => owned_buffer(json, output),
        Err(_) => PETRUNNER_OPERATION_FAILED,
    }
}

fn owned_buffer(bytes: Vec<u8>, output: *mut PetrunnerBuffer) -> i32 {
    if output.is_null() {
        return PETRUNNER_INVALID_ARGUMENT;
    }
    let mut bytes = bytes.into_boxed_slice();
    unsafe {
        *output = PetrunnerBuffer {
            data: bytes.as_mut_ptr(),
            len: bytes.len(),
        };
    }
    std::mem::forget(bytes);
    PETRUNNER_OK
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_bridge_version(output: *mut PetrunnerBuffer) -> i32 {
    boundary(|| {
        owned_buffer(
            format!("{}\0", petrunner_core::CORE_VERSION).into_bytes(),
            output,
        )
    })
}

/// Scans a pet library without ever modifying its contents. The returned UTF-8 JSON is a
/// `PetScanResult` object and is owned by Rust until `petrunner_buffer_free` is called.
#[unsafe(no_mangle)]
pub extern "C" fn petrunner_scan_pets(path: *const c_char, output: *mut PetrunnerBuffer) -> i32 {
    boundary(|| {
        let Ok(path) = (unsafe { required_utf8(path) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        match serde_json::to_vec(&scan_library(std::path::Path::new(path))) {
            Ok(json) => owned_buffer(json, output),
            Err(_) => PETRUNNER_OPERATION_FAILED,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_store_create(output: *mut *mut MonitorStoreHandle) -> i32 {
    boundary(|| {
        if output.is_null() {
            return PETRUNNER_INVALID_ARGUMENT;
        }
        unsafe {
            *output = Box::into_raw(Box::new(MonitorStoreHandle(AgentSessionStore::default())));
        }
        PETRUNNER_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_store_destroy(handle: *mut MonitorStoreHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_store_upsert_json(
    handle: *mut MonitorStoreHandle,
    event_json: *const u8,
    event_json_len: usize,
) -> i32 {
    boundary(|| {
        if handle.is_null() {
            return PETRUNNER_INVALID_HANDLE;
        }
        let Ok(event_json) = (unsafe { required_bytes(event_json, event_json_len) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(event) = serde_json::from_slice::<NormalizedAgentEvent>(event_json) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        unsafe {
            (*handle).0.upsert(event);
        }
        PETRUNNER_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_store_select_previous(handle: *mut MonitorStoreHandle) -> i32 {
    boundary(|| {
        if handle.is_null() {
            PETRUNNER_INVALID_HANDLE
        } else {
            unsafe {
                (*handle).0.select_previous();
            }
            PETRUNNER_OK
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_store_select_next(handle: *mut MonitorStoreHandle) -> i32 {
    boundary(|| {
        if handle.is_null() {
            PETRUNNER_INVALID_HANDLE
        } else {
            unsafe {
                (*handle).0.select_next();
            }
            PETRUNNER_OK
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_store_remove_json(
    handle: *mut MonitorStoreHandle,
    key_json: *const u8,
    key_json_len: usize,
) -> i32 {
    boundary(|| {
        if handle.is_null() {
            return PETRUNNER_INVALID_HANDLE;
        }
        let Ok(key_json) = (unsafe { required_bytes(key_json, key_json_len) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(key) = serde_json::from_slice(key_json) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        unsafe {
            (*handle).0.remove(&key);
        }
        PETRUNNER_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_store_set_display_name_json(
    handle: *mut MonitorStoreHandle,
    update_json: *const u8,
    update_json_len: usize,
) -> i32 {
    boundary(|| {
        if handle.is_null() {
            return PETRUNNER_INVALID_HANDLE;
        }
        let Ok(update_json) = (unsafe { required_bytes(update_json, update_json_len) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(update) = serde_json::from_slice::<DisplayNameUpdate>(update_json) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        unsafe {
            (*handle)
                .0
                .set_display_name(&update.key, update.display_name);
        }
        PETRUNNER_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_store_clear(handle: *mut MonitorStoreHandle) -> i32 {
    boundary(|| {
        if handle.is_null() {
            PETRUNNER_INVALID_HANDLE
        } else {
            unsafe {
                (*handle).0.clear();
            }
            PETRUNNER_OK
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_store_snapshot_json(
    handle: *const MonitorStoreHandle,
    output: *mut PetrunnerBuffer,
) -> i32 {
    boundary(|| {
        if handle.is_null() {
            return PETRUNNER_INVALID_HANDLE;
        }
        json_buffer(unsafe { &(*handle).0 }, output)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_decode_envelope_json(
    data: *const u8,
    len: usize,
    token: *const c_char,
    output: *mut PetrunnerBuffer,
) -> i32 {
    boundary(|| {
        let Ok(data) = (unsafe { required_bytes(data, len) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(token) = (unsafe { required_utf8(token) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        match decode_envelope(data, token) {
            Ok(event) => json_buffer(event, output),
            Err(_) => PETRUNNER_OPERATION_FAILED,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_monitor_normalize_json(
    provider: *const c_char,
    payload: *const u8,
    payload_len: usize,
    event_name: *const c_char,
    output: *mut PetrunnerBuffer,
) -> i32 {
    boundary(|| {
        let Ok(provider) = (unsafe { required_utf8(provider) }).and_then(provider_from_string)
        else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(payload) = (unsafe { required_bytes(payload, payload_len) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(event_name) = (unsafe { required_utf8(event_name) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(payload) = serde_json::from_slice(payload) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        match normalize_provider_event(provider, &payload, event_name) {
            Some(event) => json_buffer(event, output),
            None => PETRUNNER_OPERATION_FAILED,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_provider_detect_json(
    paths_json: *const u8,
    paths_json_len: usize,
    output: *mut PetrunnerBuffer,
) -> i32 {
    boundary(|| {
        let Ok(paths_json) = (unsafe { required_bytes(paths_json, paths_json_len) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(paths) = serde_json::from_slice::<std::collections::HashSet<String>>(paths_json)
        else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        json_buffer(detect_providers(&paths), output)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_provider_config_install_json(
    provider: *const c_char,
    data: *const u8,
    len: usize,
    executable_path: *const c_char,
    output: *mut PetrunnerBuffer,
) -> i32 {
    boundary(|| {
        let Ok(provider) = (unsafe { required_utf8(provider) }).and_then(provider_from_string)
        else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(data) = (unsafe { required_bytes(data, len) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(executable_path) = (unsafe { required_utf8(executable_path) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        match install_hook_configuration(provider, data, executable_path) {
            Ok(data) => owned_buffer(data, output),
            Err(_) => PETRUNNER_OPERATION_FAILED,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_provider_config_remove_json(
    provider: *const c_char,
    data: *const u8,
    len: usize,
    output: *mut PetrunnerBuffer,
) -> i32 {
    boundary(|| {
        let Ok(provider) = (unsafe { required_utf8(provider) }).and_then(provider_from_string)
        else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(data) = (unsafe { required_bytes(data, len) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        match remove_hook_configuration(provider, data) {
            Ok(data) => owned_buffer(data, output),
            Err(_) => PETRUNNER_OPERATION_FAILED,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_provider_hooks_install(
    home: *const c_char,
    providers_json: *const u8,
    providers_json_len: usize,
    executable_path: *const c_char,
) -> i32 {
    boundary(|| {
        let Ok(home) = (unsafe { required_utf8(home) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(providers_json) = (unsafe { required_bytes(providers_json, providers_json_len) })
        else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(providers) = serde_json::from_slice::<Vec<AgentProvider>>(providers_json) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(executable_path) = (unsafe { required_utf8(executable_path) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        install_provider_hooks(std::path::Path::new(home), &providers, executable_path)
            .map_or(PETRUNNER_OPERATION_FAILED, |_| PETRUNNER_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_provider_hooks_remove_all(home: *const c_char) -> i32 {
    boundary(|| {
        let Ok(home) = (unsafe { required_utf8(home) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        remove_all_provider_hooks(std::path::Path::new(home))
            .map_or(PETRUNNER_OPERATION_FAILED, |_| PETRUNNER_OK)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_cursor_title_json(
    database_path: *const c_char,
    conversation_id: *const c_char,
    output: *mut PetrunnerBuffer,
) -> i32 {
    boundary(|| {
        let Ok(database_path) = (unsafe { required_utf8(database_path) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(conversation_id) = (unsafe { required_utf8(conversation_id) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        match resolve_cursor_title(std::path::Path::new(database_path), conversation_id) {
            Some(title) => json_buffer(title, output),
            None => PETRUNNER_OPERATION_FAILED,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_buffer_free(buffer: PetrunnerBuffer) {
    if !buffer.data.is_null() && buffer.len > 0 {
        unsafe {
            drop(Box::from_raw(std::slice::from_raw_parts_mut(
                buffer.data,
                buffer.len,
            )));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_atlas_create(
    path: *const c_char,
    version: i32,
    output: *mut *mut AtlasHandle,
) -> i32 {
    boundary(|| {
        if output.is_null() {
            return PETRUNNER_INVALID_ARGUMENT;
        }
        let Ok(path) = (unsafe { required_utf8(path) }) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        let Ok(version) = SpriteVersion::try_from(version) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        match Atlas::load(std::path::Path::new(path), version) {
            Ok(atlas) => {
                unsafe {
                    *output = Box::into_raw(Box::new(AtlasHandle(atlas)));
                };
                PETRUNNER_OK
            }
            Err(_) => PETRUNNER_OPERATION_FAILED,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_atlas_destroy(handle: *mut AtlasHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_atlas_frame_png(
    handle: *const AtlasHandle,
    row: i32,
    column: i32,
    output: *mut PetrunnerBuffer,
) -> i32 {
    boundary(|| {
        if handle.is_null() {
            return PETRUNNER_INVALID_HANDLE;
        }
        match unsafe { &(*handle).0 }.frame_png(CoreAtlasAddress { row, column }) {
            Ok(frame) => owned_buffer(frame, output),
            Err(_) => PETRUNNER_OPERATION_FAILED,
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_animation_create(
    initial_state: i32,
    output: *mut *mut AnimationHandle,
) -> i32 {
    boundary(|| {
        if output.is_null() {
            return PETRUNNER_INVALID_ARGUMENT;
        }
        let Ok(state) = AnimationState::try_from(initial_state) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        unsafe {
            *output = Box::into_raw(Box::new(AnimationHandle(AnimationPlayback::new(
                state,
                vec![],
                0,
            ))));
        }
        PETRUNNER_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_animation_frame_count(state: i32) -> i32 {
    boundary(|| {
        AnimationState::try_from(state).map_or(PETRUNNER_INVALID_ARGUMENT, |state| {
            state.frame_durations().len() as i32
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_animation_frame_duration(state: i32, index: i32) -> f64 {
    catch_unwind(AssertUnwindSafe(|| {
        let Ok(state) = AnimationState::try_from(state) else {
            return -1.0;
        };
        let Ok(index) = usize::try_from(index) else {
            return -1.0;
        };
        state.frame_durations().get(index).copied().unwrap_or(-1.0)
    }))
    .unwrap_or(-1.0)
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_animation_cycles_before_idle(state: i32) -> i32 {
    boundary(|| {
        AnimationState::try_from(state).map_or(PETRUNNER_INVALID_ARGUMENT, |state| {
            state.cycles_before_idle().unwrap_or(0) as i32
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_animation_destroy(handle: *mut AnimationHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_animation_start(handle: *mut AnimationHandle, state: i32) -> i32 {
    boundary(|| {
        if handle.is_null() {
            return PETRUNNER_INVALID_HANDLE;
        }
        let Ok(state) = AnimationState::try_from(state) else {
            return PETRUNNER_INVALID_ARGUMENT;
        };
        unsafe {
            (*handle).0.start(state);
        }
        PETRUNNER_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_animation_advance(
    handle: *mut AnimationHandle,
    delta_time: f64,
) -> i32 {
    boundary(|| {
        if handle.is_null() {
            return PETRUNNER_INVALID_HANDLE;
        }
        unsafe {
            (*handle).0.advance(delta_time);
        }
        PETRUNNER_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_animation_snapshot(
    handle: *const AnimationHandle,
    output: *mut PetrunnerAnimationSnapshot,
) -> i32 {
    boundary(|| {
        if handle.is_null() {
            return PETRUNNER_INVALID_HANDLE;
        }
        if output.is_null() {
            return PETRUNNER_INVALID_ARGUMENT;
        }
        let animation = unsafe { &(*handle).0 };
        let address = animation.atlas_address();
        unsafe {
            *output = PetrunnerAnimationSnapshot {
                state: animation.state() as i32,
                frame_index: animation.frame_index() as i32,
                elapsed_in_frame: animation.elapsed_in_frame(),
                row: address.row,
                column: address.column,
            };
        }
        PETRUNNER_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_look_direction(
    dx: f64,
    dy: f64,
    deadzone: f64,
    output: *mut PetrunnerAtlasAddress,
) -> bool {
    boundary(|| {
        if output.is_null() {
            return PETRUNNER_INVALID_ARGUMENT;
        }
        let Some(frame) = LookDirection::frame_index(dx, dy, deadzone) else {
            return PETRUNNER_OPERATION_FAILED;
        };
        let Some(address) = LookDirection::atlas_address(frame) else {
            return PETRUNNER_OPERATION_FAILED;
        };
        unsafe {
            *output = PetrunnerAtlasAddress {
                row: address.row,
                column: address.column,
            };
        }
        PETRUNNER_OK
    }) == PETRUNNER_OK
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_physics_step(
    motion: *mut PetrunnerMotionState,
    size: PetrunnerSize,
    bounds: PetrunnerRect,
    retention: f64,
    restitution: f64,
    stop_speed: f64,
    maximum_delta_time: f64,
    delta_time: f64,
    output: *mut PetrunnerPhysicsResult,
) -> i32 {
    boundary(|| {
        if motion.is_null() || output.is_null() {
            return PETRUNNER_INVALID_ARGUMENT;
        }
        let mut core_motion = CoreMotionState::from(unsafe { *motion });
        let result = PhysicsConfig {
            velocity_retention_per_second: retention,
            restitution,
            stop_speed,
            maximum_delta_time,
        }
        .step(&mut core_motion, size.into(), bounds.into(), delta_time);
        unsafe {
            *motion = core_motion.into();
        }
        unsafe {
            *output = PetrunnerPhysicsResult {
                horizontal_bounce: result.0,
                vertical_bounce: result.1,
            };
        }
        PETRUNNER_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn petrunner_physics_clamp(
    origin_x: f64,
    origin_y: f64,
    size: PetrunnerSize,
    bounds: PetrunnerRect,
    output: *mut PetrunnerMotionState,
) -> i32 {
    boundary(|| {
        if output.is_null() {
            return PETRUNNER_INVALID_ARGUMENT;
        }
        let (x, y) = PhysicsConfig::clamped_origin(origin_x, origin_y, size.into(), bounds.into());
        unsafe {
            *output = PetrunnerMotionState {
                x,
                y,
                velocity_x: 0.0,
                velocity_y: 0.0,
            };
        }
        PETRUNNER_OK
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr;

    #[test]
    fn version_buffer_has_one_owner() {
        let mut buffer = PetrunnerBuffer {
            data: ptr::null_mut(),
            len: 0,
        };
        assert_eq!(petrunner_bridge_version(&mut buffer), PETRUNNER_OK);
        assert!(!buffer.data.is_null());
        petrunner_buffer_free(buffer);
    }

    #[test]
    fn invalid_handles_are_controlled_errors() {
        assert_eq!(
            petrunner_animation_advance(ptr::null_mut(), 0.1),
            PETRUNNER_INVALID_HANDLE
        );
        assert_eq!(
            petrunner_atlas_frame_png(ptr::null(), 0, 0, ptr::null_mut()),
            PETRUNNER_INVALID_HANDLE
        );
    }

    #[test]
    fn empty_foreign_buffers_do_not_require_a_non_null_pointer() {
        assert_eq!(
            unsafe { required_bytes(std::ptr::null(), 0) }.unwrap(),
            &[] as &[u8]
        );
    }
}
