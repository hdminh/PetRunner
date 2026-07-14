//! Platform-neutral PetRunner domain logic.
//!
//! This crate intentionally does not depend on AppKit, WPF, Cocoa, or Win32.
//! Native hosts reach it through `petrunner-bridge`.

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

pub mod animation;
pub mod atlas;
pub mod monitor;
pub mod pet;
pub mod physics;

pub use animation::{AnimationPlayback, AnimationState, AtlasAddress, IdleAction, LookDirection};
pub use atlas::{Atlas, AtlasError, SpriteVersion};
pub use monitor::{
    AgentProvider, AgentSessionStore, AgentStatus, DisplayName, DisplayNameSource,
    NormalizedAgentEvent, ProviderDetection, decode_envelope, detect_providers,
    install_hook_configuration, install_provider_hooks, normalize_provider_event,
    remove_all_provider_hooks, remove_hook_configuration, resolve_cursor_title,
};
pub use pet::{PetDescriptor, PetFailure, PetScanResult, scan_library};
pub use physics::{MotionState, PhysicsConfig, Rect, Size};
