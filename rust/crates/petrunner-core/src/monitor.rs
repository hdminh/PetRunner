use std::{
    collections::HashSet,
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use thiserror::Error;

use crate::AnimationState;

pub const MAXIMUM_MONITOR_ENVELOPE_BYTES: usize = 4_096;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentProvider {
    Claude,
    Codex,
    Cursor,
}

impl AgentProvider {
    #[must_use]
    pub const fn display_label(self) -> &'static str {
        match self {
            Self::Claude => "CLAUDE",
            Self::Codex => "CODEX",
            Self::Cursor => "CURSOR",
        }
    }
    #[must_use]
    pub const fn config_path(self) -> &'static str {
        match self {
            Self::Claude => ".claude/settings.json",
            Self::Codex => ".codex/hooks.json",
            Self::Cursor => ".cursor/hooks.json",
        }
    }
    #[must_use]
    pub const fn events(self) -> &'static [&'static str] {
        match self {
            Self::Claude => &[
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PermissionRequest",
                "PostToolUse",
                "PostToolUseFailure",
                "Stop",
                "StopFailure",
            ],
            Self::Codex => &[
                "SessionStart",
                "UserPromptSubmit",
                "PreToolUse",
                "PermissionRequest",
                "PostToolUse",
                "Stop",
            ],
            Self::Cursor => &[
                "sessionStart",
                "beforeSubmitPrompt",
                "preToolUse",
                "postToolUse",
                "postToolUseFailure",
                "stop",
                "sessionEnd",
            ],
        }
    }
    #[must_use]
    pub const fn all() -> [Self; 3] {
        [Self::Claude, Self::Codex, Self::Cursor]
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentStatus {
    Working,
    Reviewing,
    NeedsApproval,
    Finished,
    Failed,
}

impl AgentStatus {
    #[must_use]
    pub const fn display_text(self) -> &'static str {
        match self {
            Self::Working => "Working…",
            Self::Reviewing => "Reviewing…",
            Self::NeedsApproval => "Needs approval",
            Self::Finished => "Finished",
            Self::Failed => "Failed",
        }
    }
    #[must_use]
    pub const fn detail_text(self) -> &'static str {
        match self {
            Self::Working => "WORKING ON TASK",
            Self::Reviewing => "REVIEWING CHANGES",
            Self::NeedsApproval => "WAITING FOR YOU",
            Self::Finished => "TURN COMPLETE",
            Self::Failed => "TURN FAILED",
        }
    }
    #[must_use]
    pub const fn animation(self) -> AnimationState {
        match self {
            Self::Working => AnimationState::Running,
            Self::Reviewing => AnimationState::Review,
            Self::NeedsApproval => AnimationState::Waiting,
            Self::Finished => AnimationState::Waving,
            Self::Failed => AnimationState::Failed,
        }
    }
    #[must_use]
    pub const fn tone(self) -> &'static str {
        match self {
            Self::Working => "yellow",
            Self::Reviewing => "cyan",
            Self::NeedsApproval => "violet",
            Self::Finished => "green",
            Self::Failed => "red",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DisplayNameSource {
    Prompt,
    NativeProvider,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct DisplayName {
    pub value: String,
    pub source: DisplayNameSource,
}

impl DisplayName {
    #[must_use]
    pub fn sanitized(value: &str, source: DisplayNameSource) -> Option<Self> {
        let collapsed = value.split_whitespace().collect::<Vec<_>>().join(" ");
        if collapsed.is_empty() {
            return None;
        }
        let mut output = String::new();
        let mut bytes = 0;
        for character in collapsed.chars().take(96) {
            let width = character.len_utf8();
            if bytes + width > 384 {
                break;
            }
            output.push(character);
            bytes += width;
        }
        (!output.is_empty()).then_some(Self {
            value: output,
            source,
        })
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSessionKey {
    pub provider: AgentProvider,
    pub session_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NormalizedAgentEvent {
    pub provider: AgentProvider,
    pub session_id: String,
    pub status: AgentStatus,
    pub display_name: Option<DisplayName>,
}

impl NormalizedAgentEvent {
    #[must_use]
    pub fn key(&self) -> AgentSessionKey {
        AgentSessionKey {
            provider: self.provider,
            session_id: self.session_id.clone(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSessionSnapshot {
    pub key: AgentSessionKey,
    pub status: AgentStatus,
    pub display_name: Option<DisplayName>,
    pub display_text: &'static str,
    pub detail_text: String,
    pub animation: i32,
    pub indicator_tone: &'static str,
}

impl AgentSessionSnapshot {
    fn new(key: AgentSessionKey, status: AgentStatus, display_name: Option<DisplayName>) -> Self {
        Self {
            detail_text: display_name.as_ref().map_or_else(
                || status.detail_text().to_owned(),
                |name| name.value.clone(),
            ),
            display_text: status.display_text(),
            animation: status.animation() as i32,
            indicator_tone: status.tone(),
            key,
            status,
            display_name,
        }
    }
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSessionStore {
    entries: Vec<AgentSessionSnapshot>,
    selected_index: usize,
}

impl AgentSessionStore {
    pub const MAXIMUM_ENTRIES: usize = 5;
    #[must_use]
    pub fn entries(&self) -> &[AgentSessionSnapshot] {
        &self.entries
    }
    #[must_use]
    pub const fn selected_index(&self) -> usize {
        self.selected_index
    }
    #[must_use]
    pub fn selected(&self) -> Option<&AgentSessionSnapshot> {
        self.entries.get(self.selected_index)
    }
    pub fn upsert(&mut self, event: NormalizedAgentEvent) {
        let key = event.key();
        let existing = self
            .entries
            .iter()
            .find(|entry| entry.key == key)
            .and_then(|entry| entry.display_name.clone());
        let name = preferred_display_name(existing, event.display_name);
        self.entries.retain(|entry| entry.key != key);
        self.entries
            .insert(0, AgentSessionSnapshot::new(key, event.status, name));
        self.entries.truncate(Self::MAXIMUM_ENTRIES);
        self.selected_index = 0;
    }
    pub fn set_display_name(&mut self, key: &AgentSessionKey, name: DisplayName) -> bool {
        let Some(index) = self.entries.iter().position(|entry| &entry.key == key) else {
            return false;
        };
        let entry = &self.entries[index];
        let Some(name) = preferred_display_name(entry.display_name.clone(), Some(name)) else {
            return false;
        };
        if entry.display_name.as_ref() == Some(&name) {
            return false;
        }
        self.entries[index] =
            AgentSessionSnapshot::new(entry.key.clone(), entry.status, Some(name));
        true
    }
    pub fn select_previous(&mut self) {
        self.selected_index = self.selected_index.saturating_sub(1);
    }
    pub fn select_next(&mut self) {
        self.selected_index = self
            .selected_index
            .saturating_add(1)
            .min(self.entries.len().saturating_sub(1));
    }
    pub fn select(&mut self, index: usize) -> bool {
        if index >= self.entries.len() {
            false
        } else {
            self.selected_index = index;
            true
        }
    }
    pub fn remove(&mut self, key: &AgentSessionKey) -> bool {
        let selected_key = self.selected().map(|entry| entry.key.clone());
        let original = self.entries.len();
        self.entries.retain(|entry| &entry.key != key);
        if self.entries.len() == original {
            return false;
        }
        self.selected_index = selected_key
            .and_then(|selected| self.entries.iter().position(|entry| entry.key == selected))
            .unwrap_or_else(|| {
                self.selected_index
                    .min(self.entries.len().saturating_sub(1))
            });
        true
    }
    pub fn clear(&mut self) {
        self.entries.clear();
        self.selected_index = 0;
    }
}

fn preferred_display_name(
    existing: Option<DisplayName>,
    candidate: Option<DisplayName>,
) -> Option<DisplayName> {
    match (existing, candidate) {
        (None, candidate) => candidate,
        (existing @ Some(_), None) => existing,
        (Some(existing), Some(candidate))
            if candidate.source > existing.source
                || (candidate.source == DisplayNameSource::NativeProvider
                    && candidate.value != existing.value) =>
        {
            Some(candidate)
        }
        (Some(existing), Some(_)) => Some(existing),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Envelope {
    version: i32,
    token: String,
    provider: AgentProvider,
    session_id: String,
    status: AgentStatus,
    display_name: Option<DisplayName>,
}

#[derive(Debug, Error)]
pub enum MonitorError {
    #[error("malformed monitor envelope")]
    MalformedEnvelope,
    #[error("monitor protocol version is unsupported")]
    UnsupportedVersion,
    #[error("monitor token is invalid")]
    InvalidToken,
    #[error("monitor session id is invalid")]
    InvalidSession,
    #[error("monitor envelope is oversized")]
    OversizedEnvelope,
    #[error("provider configuration is malformed JSON")]
    MalformedJson,
    #[error("provider configuration root is unsupported")]
    UnsupportedRoot,
    #[error("provider hook shape is unsupported")]
    UnsupportedHookShape,
    #[error("Cursor hook configuration version is unsupported")]
    UnsupportedCursorVersion,
    #[error("PetRunner hook is missing after write")]
    MissingInstalledHook,
    #[error("{0}")]
    Io(String),
}

pub fn decode_envelope(
    data: &[u8],
    expected_token: &str,
) -> Result<NormalizedAgentEvent, MonitorError> {
    if data.len() > MAXIMUM_MONITOR_ENVELOPE_BYTES {
        return Err(MonitorError::OversizedEnvelope);
    }
    let envelope: Envelope =
        serde_json::from_slice(data).map_err(|_| MonitorError::MalformedEnvelope)?;
    if envelope.version != 1 {
        return Err(MonitorError::UnsupportedVersion);
    }
    if expected_token.is_empty() || envelope.token != expected_token {
        return Err(MonitorError::InvalidToken);
    }
    if envelope.session_id.trim().is_empty() {
        return Err(MonitorError::InvalidSession);
    }
    Ok(NormalizedAgentEvent {
        provider: envelope.provider,
        session_id: envelope.session_id,
        status: envelope.status,
        display_name: envelope.display_name,
    })
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderDetection {
    pub provider: AgentProvider,
    pub is_detected: bool,
}

#[must_use]
pub fn detect_providers(existing_paths: &HashSet<String>) -> Vec<ProviderDetection> {
    AgentProvider::all()
        .into_iter()
        .map(|provider| {
            let hints: &[&str] = match provider {
                AgentProvider::Claude => &[".claude", ".claude/settings.json"],
                AgentProvider::Codex => &[".codex", ".codex/hooks.json"],
                AgentProvider::Cursor => &[".cursor", ".cursor/hooks.json"],
            };
            ProviderDetection {
                provider,
                is_detected: hints.iter().any(|hint| existing_paths.contains(*hint)),
            }
        })
        .collect()
}

pub const OWNERSHIP_MARKER: &str = "--pet-runner-monitor";

#[must_use]
pub fn normalize_provider_event(
    provider: AgentProvider,
    payload: &Value,
    event_name: &str,
) -> Option<NormalizedAgentEvent> {
    let payload = payload.as_object()?;
    let session_id = match provider {
        AgentProvider::Cursor => {
            value_string(payload, "conversation_id").or_else(|| value_string(payload, "session_id"))
        }
        _ => value_string(payload, "session_id"),
    }?;
    if session_id.is_empty() {
        return None;
    }
    let event = event_name.to_ascii_lowercase();
    let status = if event.contains("permission") {
        (provider != AgentProvider::Cursor).then_some(AgentStatus::NeedsApproval)
    } else if event.contains("failure")
        || value_string(payload, "status").is_some_and(|status| status == "error")
    {
        Some(AgentStatus::Failed)
    } else if event == "stop" || event.contains("sessionend") {
        Some(AgentStatus::Finished)
    } else if event.contains("tool") {
        Some(
            if is_read_only_tool(
                value_string(payload, "tool_name").or_else(|| value_string(payload, "toolName")),
            ) {
                AgentStatus::Reviewing
            } else {
                AgentStatus::Working
            },
        )
    } else if event.contains("prompt") || event.contains("sessionstart") {
        Some(AgentStatus::Working)
    } else {
        None
    }?;
    let wants_prompt = matches!(provider, AgentProvider::Claude | AgentProvider::Codex)
        && event == "userpromptsubmit"
        || provider == AgentProvider::Cursor && event == "beforesubmitprompt";
    let display_name = wants_prompt
        .then(|| {
            value_string(payload, "prompt")
                .and_then(|prompt| DisplayName::sanitized(prompt, DisplayNameSource::Prompt))
        })
        .flatten();
    Some(NormalizedAgentEvent {
        provider,
        session_id: session_id.to_owned(),
        status,
        display_name,
    })
}

fn value_string<'a>(payload: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    payload.get(key)?.as_str()
}
fn is_read_only_tool(tool: Option<&str>) -> bool {
    tool.is_some_and(|tool| {
        ["read", "search", "grep", "glob", "find", "list"]
            .iter()
            .any(|needle| tool.to_ascii_lowercase().contains(needle))
    })
}

pub fn install_provider_hooks(
    home: &Path,
    providers: &[AgentProvider],
    executable_path: &str,
) -> Result<(), MonitorError> {
    let mut unique = HashSet::new();
    let mut updates = Vec::new();
    for provider in providers
        .iter()
        .copied()
        .filter(|provider| unique.insert(*provider))
    {
        if let Some(update) = prepare_hook_update(home, provider, executable_path, false)? {
            updates.push(update);
        }
    }
    write_hook_updates(updates)
}

pub fn remove_all_provider_hooks(home: &Path) -> Result<(), MonitorError> {
    let mut updates = Vec::new();
    for provider in AgentProvider::all() {
        if let Some(update) = prepare_hook_update(home, provider, "", true)? {
            updates.push(update);
        }
    }
    write_hook_updates(updates)
}

struct HookUpdate {
    provider: AgentProvider,
    home: PathBuf,
    path: PathBuf,
    existed: bool,
    input: Vec<u8>,
    output: Vec<u8>,
    permissions: Option<fs::Permissions>,
    executable_path: String,
    removing: bool,
}

fn prepare_hook_update(
    home: &Path,
    provider: AgentProvider,
    executable_path: &str,
    removing: bool,
) -> Result<Option<HookUpdate>, MonitorError> {
    let path = home.join(provider.config_path());
    reject_symlinked_config_ancestors(home, &path)?;
    let metadata = path_metadata(&path)?;
    if removing && metadata.is_none() {
        return Ok(None);
    }
    if let Some(metadata) = &metadata
        && (!metadata.file_type().is_file() || metadata.file_type().is_symlink())
    {
        return Err(MonitorError::Io(format!(
            "{} is not a regular configuration file",
            path.display()
        )));
    }
    let existed = metadata.is_some();
    let permissions = if existed {
        Some(
            fs::metadata(&path)
                .map_err(|error| MonitorError::Io(error.to_string()))?
                .permissions(),
        )
    } else {
        None
    };
    let input = if existed {
        fs::read(&path).map_err(|error| MonitorError::Io(error.to_string()))?
    } else {
        b"{}".to_vec()
    };
    let output = if removing {
        remove_hook_configuration(provider, &input)?
    } else {
        install_hook_configuration(provider, &input, executable_path)?
    };
    if !removing {
        verify_hook_configuration(provider, &output, executable_path)?;
    }
    Ok(Some(HookUpdate {
        provider,
        home: home.to_path_buf(),
        path,
        existed,
        input,
        output,
        permissions,
        executable_path: executable_path.to_owned(),
        removing,
    }))
}

fn path_metadata(path: &Path) -> Result<Option<fs::Metadata>, MonitorError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(MonitorError::Io(error.to_string())),
    }
}

fn reject_symlinked_config_ancestors(home: &Path, path: &Path) -> Result<(), MonitorError> {
    let relative = path.strip_prefix(home).map_err(|_| {
        MonitorError::Io(format!(
            "{} is outside the selected home directory",
            path.display()
        ))
    })?;
    let mut current = home.to_path_buf();
    let components = relative.components().collect::<Vec<_>>();
    for component in components.iter().take(components.len().saturating_sub(1)) {
        current.push(component.as_os_str());
        if let Some(metadata) = path_metadata(&current)?
            && metadata.file_type().is_symlink()
        {
            return Err(MonitorError::Io(format!(
                "{} has a symlinked configuration directory",
                current.display()
            )));
        }
    }
    Ok(())
}

fn write_hook_updates(updates: Vec<HookUpdate>) -> Result<(), MonitorError> {
    let mut written = Vec::new();
    for update in updates {
        reject_symlinked_config_ancestors(&update.home, &update.path)?;
        if update.existed
            && fs::read(&update.path).map_err(|error| MonitorError::Io(error.to_string()))?
                != update.input
        {
            restore_hook_updates(&written);
            return Err(MonitorError::Io(format!(
                "{} changed during hook update",
                update.path.display()
            )));
        }
        if !update.existed && path_metadata(&update.path)?.is_some() {
            restore_hook_updates(&written);
            return Err(MonitorError::Io(format!(
                "{} was created during hook update",
                update.path.display()
            )));
        }
        if let Err(error) = write_hook_update(&update) {
            restore_hook_updates(&written);
            return Err(error);
        }
        written.push(update);
    }
    Ok(())
}

fn write_hook_update(update: &HookUpdate) -> Result<(), MonitorError> {
    let parent = update
        .path
        .parent()
        .ok_or_else(|| MonitorError::Io("hook path has no parent".to_owned()))?;
    fs::create_dir_all(parent).map_err(|error| MonitorError::Io(error.to_string()))?;
    let (temporary, mut temporary_file) = create_temporary_hook_file(parent, &update.path)?;
    if let Err(error) = temporary_file.write_all(&update.output) {
        let _ = fs::remove_file(&temporary);
        return Err(MonitorError::Io(error.to_string()));
    }
    if let Err(error) = temporary_file.sync_all() {
        let _ = fs::remove_file(&temporary);
        return Err(MonitorError::Io(error.to_string()));
    }
    drop(temporary_file);
    fs::rename(&temporary, &update.path).map_err(|error| MonitorError::Io(error.to_string()))?;
    if let Some(permissions) = &update.permissions {
        fs::set_permissions(&update.path, permissions.clone())
            .map_err(|error| MonitorError::Io(error.to_string()))?;
    } else {
        set_new_hook_permissions(&update.path)?;
    }
    if !update.removing {
        verify_hook_configuration(
            update.provider,
            &fs::read(&update.path).map_err(|error| MonitorError::Io(error.to_string()))?,
            &update.executable_path,
        )?;
    }
    Ok(())
}

fn create_temporary_hook_file(
    parent: &Path,
    path: &Path,
) -> Result<(PathBuf, fs::File), MonitorError> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("hooks");
    for counter in 0..32_u8 {
        let temporary = parent.join(format!(
            ".{name}.petrunner-{}-{counter}.tmp",
            std::process::id()
        ));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => return Ok((temporary, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(MonitorError::Io(error.to_string())),
        }
    }
    Err(MonitorError::Io(
        "could not reserve a temporary hook configuration file".to_owned(),
    ))
}

fn restore_hook_updates(updates: &[HookUpdate]) {
    for update in updates.iter().rev() {
        if update.existed {
            let _ = fs::write(&update.path, &update.input);
            if let Some(permissions) = &update.permissions {
                let _ = fs::set_permissions(&update.path, permissions.clone());
            }
        } else {
            let _ = fs::remove_file(&update.path);
        }
    }
}

fn set_new_hook_permissions(path: &Path) -> Result<(), MonitorError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| MonitorError::Io(error.to_string()))?;
    }
    Ok(())
}

pub fn install_hook_configuration(
    provider: AgentProvider,
    data: &[u8],
    executable_path: &str,
) -> Result<Vec<u8>, MonitorError> {
    let mut root = hook_root(provider, data)?;
    let hooks = hooks_from_root(&root)?;
    let mut hooks = remove_owned_entries(hooks)?;
    for event in provider.events() {
        let entries = hooks
            .remove(*event)
            .map_or(Ok(Vec::new()), |value| hook_entries(&value))?;
        let mut entries = entries;
        let command = hook_command(provider, executable_path, event);
        entries.push(
            if matches!(provider, AgentProvider::Claude | AgentProvider::Codex) {
                serde_json::json!({"hooks":[{"type":"command","command":command}]})
            } else {
                serde_json::json!({"command":command})
            },
        );
        hooks.insert((*event).to_owned(), Value::Array(entries));
    }
    root.insert("hooks".to_owned(), Value::Object(hooks));
    if provider == AgentProvider::Cursor {
        root.insert("version".to_owned(), Value::from(1));
    }
    serde_json::to_vec_pretty(&Value::Object(root)).map_err(|_| MonitorError::MalformedJson)
}

pub fn remove_hook_configuration(
    provider: AgentProvider,
    data: &[u8],
) -> Result<Vec<u8>, MonitorError> {
    let mut root = hook_root(provider, data)?;
    let hooks = hooks_from_root(&root)?;
    let hooks = remove_owned_entries(hooks)?;
    if hooks.is_empty() {
        root.remove("hooks");
    } else {
        root.insert("hooks".to_owned(), Value::Object(hooks));
    }
    serde_json::to_vec_pretty(&Value::Object(root)).map_err(|_| MonitorError::MalformedJson)
}

pub fn verify_hook_configuration(
    provider: AgentProvider,
    data: &[u8],
    executable_path: &str,
) -> Result<(), MonitorError> {
    let root = hook_root(provider, data)?;
    let hooks = hooks_from_root(&root)?;
    for event in provider.events() {
        let entries = hooks
            .get(*event)
            .ok_or(MonitorError::MissingInstalledHook)
            .and_then(hook_entries)?;
        let expected = hook_command(provider, executable_path, event);
        if !entries
            .iter()
            .any(|entry| entry_command_contains(entry, &expected))
        {
            return Err(MonitorError::MissingInstalledHook);
        }
    }
    Ok(())
}

fn hook_root(provider: AgentProvider, data: &[u8]) -> Result<Map<String, Value>, MonitorError> {
    let value = if data.is_empty() {
        Value::Object(Map::new())
    } else {
        serde_json::from_slice(data).map_err(|_| MonitorError::MalformedJson)?
    };
    let root = value
        .as_object()
        .ok_or(MonitorError::UnsupportedRoot)?
        .clone();
    if provider == AgentProvider::Cursor
        && root
            .get("version")
            .is_some_and(|version| version.as_i64() != Some(1))
    {
        return Err(MonitorError::UnsupportedCursorVersion);
    }
    Ok(root)
}

fn hooks_from_root(root: &Map<String, Value>) -> Result<Map<String, Value>, MonitorError> {
    root.get("hooks").map_or(Ok(Map::new()), |value| {
        value
            .as_object()
            .cloned()
            .ok_or(MonitorError::UnsupportedHookShape)
    })
}
fn hook_entries(value: &Value) -> Result<Vec<Value>, MonitorError> {
    let entries = value
        .as_array()
        .ok_or(MonitorError::UnsupportedHookShape)?
        .clone();
    if entries.iter().all(Value::is_object) {
        Ok(entries)
    } else {
        Err(MonitorError::UnsupportedHookShape)
    }
}
fn remove_owned_entries(hooks: Map<String, Value>) -> Result<Map<String, Value>, MonitorError> {
    let mut result = Map::new();
    for (event, value) in hooks {
        let entries = hook_entries(&value)?;
        let retained = clean_hook_entries(entries)?;
        if !retained.is_empty() {
            result.insert(event, Value::Array(retained));
        }
    }
    Ok(result)
}
fn clean_hook_entry(entry: Value) -> Result<Option<Value>, MonitorError> {
    let mut entry = entry
        .as_object()
        .ok_or(MonitorError::UnsupportedHookShape)?
        .clone();
    if let Some(command) = entry.get("command") {
        let command = command.as_str().ok_or(MonitorError::UnsupportedHookShape)?;
        return Ok((!command.contains(OWNERSHIP_MARKER)).then_some(Value::Object(entry)));
    }
    if let Some(nested) = entry.get("hooks") {
        let retained = clean_hook_entries(hook_entries(nested)?)?;
        if retained.is_empty() {
            return Ok(None);
        }
        entry.insert("hooks".to_owned(), Value::Array(retained));
    }
    Ok(Some(Value::Object(entry)))
}
fn clean_hook_entries(entries: Vec<Value>) -> Result<Vec<Value>, MonitorError> {
    let mut retained = Vec::new();
    for entry in entries {
        if let Some(entry) = clean_hook_entry(entry)? {
            retained.push(entry);
        }
    }
    Ok(retained)
}
fn entry_command_contains(entry: &Value, expected: &str) -> bool {
    entry
        .get("command")
        .and_then(Value::as_str)
        .is_some_and(|command| command == expected)
        || entry
            .get("hooks")
            .and_then(Value::as_array)
            .is_some_and(|entries| {
                entries
                    .iter()
                    .any(|nested| entry_command_contains(nested, expected))
            })
}
fn hook_command(provider: AgentProvider, executable_path: &str, event: &str) -> String {
    format!(
        "{} --agent-monitor-hook --provider {} --event {} {OWNERSHIP_MARKER}",
        shell_quote(executable_path),
        match provider {
            AgentProvider::Claude => "claude",
            AgentProvider::Codex => "codex",
            AgentProvider::Cursor => "cursor",
        },
        shell_quote(event)
    )
}
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\\"'\\\"'"))
}

#[must_use]
pub fn resolve_cursor_title(database_path: &Path, conversation_id: &str) -> Option<DisplayName> {
    if conversation_id.trim().is_empty() {
        return None;
    }
    let connection = Connection::open_with_flags(
        database_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
    )
    .ok()?;
    connection
        .busy_timeout(std::time::Duration::from_millis(50))
        .ok()?;
    let title = connection
        .query_row(
            "SELECT title FROM conversations WHERE id = ? LIMIT 1",
            [conversation_id],
            |row| row.get::<_, String>(0),
        )
        .ok()?;
    DisplayName::sanitized(&title, DisplayNameSource::NativeProvider)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_names_are_bounded_and_session_store_is_mru() {
        let mut store = AgentSessionStore::default();
        store.upsert(NormalizedAgentEvent {
            provider: AgentProvider::Claude,
            session_id: "one".to_owned(),
            status: AgentStatus::Working,
            display_name: None,
        });
        store.upsert(NormalizedAgentEvent {
            provider: AgentProvider::Codex,
            session_id: "two".to_owned(),
            status: AgentStatus::Reviewing,
            display_name: None,
        });
        assert_eq!(store.entries()[0].key.session_id, "two");
        assert_eq!(
            DisplayName::sanitized(&"x".repeat(100), DisplayNameSource::Prompt)
                .unwrap()
                .value
                .chars()
                .count(),
            96
        );
    }

    #[test]
    fn envelope_requires_matching_token_and_protocol() {
        let input = br#"{"version":1,"token":"secret","provider":"claude","sessionId":"one","status":"working"}"#;
        assert!(decode_envelope(input, "secret").is_ok());
        assert_eq!(
            decode_envelope(input, "other").unwrap_err().to_string(),
            "monitor token is invalid"
        );
    }

    #[test]
    fn hook_configuration_keeps_third_party_hook_and_is_idempotent() {
        let input = br#"{"version":1,"hooks":{"stop":[{"command":"other-command"}]}}"#;
        let installed =
            install_hook_configuration(AgentProvider::Cursor, input, "/tmp/pet").unwrap();
        verify_hook_configuration(AgentProvider::Cursor, &installed, "/tmp/pet").unwrap();
        assert!(
            String::from_utf8(installed)
                .unwrap()
                .contains("other-command")
        );
    }

    #[cfg(unix)]
    #[test]
    fn provider_hook_install_rejects_symlinked_configuration_files() {
        use std::os::unix::fs::symlink;

        let home = tempfile::tempdir().unwrap();
        let external = tempfile::tempdir().unwrap();
        let external_config = external.path().join("settings.json");
        std::fs::write(&external_config, b"{}").unwrap();
        std::fs::create_dir(home.path().join(".claude")).unwrap();
        symlink(&external_config, home.path().join(".claude/settings.json")).unwrap();

        let error =
            install_provider_hooks(home.path(), &[AgentProvider::Claude], "/tmp/pet").unwrap_err();

        assert!(
            error
                .to_string()
                .contains("not a regular configuration file")
        );
        assert_eq!(std::fs::read(&external_config).unwrap(), b"{}");

        let directory_home = tempfile::tempdir().unwrap();
        let external_directory = tempfile::tempdir().unwrap();
        std::fs::write(external_directory.path().join("settings.json"), b"{}").unwrap();
        symlink(
            external_directory.path(),
            directory_home.path().join(".claude"),
        )
        .unwrap();

        let error =
            install_provider_hooks(directory_home.path(), &[AgentProvider::Claude], "/tmp/pet")
                .unwrap_err();

        assert!(
            error
                .to_string()
                .contains("symlinked configuration directory")
        );
    }
}
