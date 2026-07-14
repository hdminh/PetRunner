use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{Atlas, AtlasError, SpriteVersion};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PetDescriptor {
    pub id: String,
    pub display_name: String,
    pub description: Option<String>,
    pub version: i32,
    pub package_path: PathBuf,
    pub spritesheet_path: PathBuf,
}

impl PetDescriptor {
    #[must_use]
    pub fn sprite_version(&self) -> SpriteVersion {
        // Construction validates this invariant.
        SpriteVersion::try_from(self.version).expect("validated sprite version")
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PetFailure {
    pub id: String,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PetScanResult {
    pub valid: Vec<PetDescriptor>,
    pub invalid: Vec<PetFailure>,
}

#[derive(Debug, Error)]
pub enum PetLoadError {
    #[error("pet.json is missing")]
    ManifestMissing,
    #[error("pet.json is invalid: {0}")]
    ManifestInvalid(serde_json::Error),
    #[error("spriteVersionNumber {0} is unsupported")]
    UnsupportedVersion(i32),
    #[error("spritesheet extension .{0} is unsupported")]
    UnsupportedSpritesheetExtension(String),
    #[error("spritesheetPath escapes the pet directory")]
    SpritesheetOutsidePackage,
    #[error("spritesheet file is missing")]
    SpritesheetMissing,
    #[error("spritesheet cannot be decoded")]
    UnreadableSpritesheet,
    #[error(transparent)]
    Atlas(AtlasError),
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    id: Option<String>,
    display_name: Option<String>,
    description: Option<String>,
    sprite_version_number: Option<i32>,
    spritesheet_path: Option<String>,
}

pub fn load_package(directory: &Path) -> Result<PetDescriptor, PetLoadError> {
    let package_path = directory
        .canonicalize()
        .map_err(|_| PetLoadError::ManifestMissing)?;
    let manifest_path = package_path.join("pet.json");
    if !manifest_path.is_file() {
        return Err(PetLoadError::ManifestMissing);
    }
    let manifest_data = fs::read(&manifest_path).map_err(|_| PetLoadError::ManifestMissing)?;
    let manifest = serde_json::from_slice::<Manifest>(&manifest_data)
        .map_err(PetLoadError::ManifestInvalid)?;
    let raw_version = manifest.sprite_version_number.unwrap_or(1);
    let version = SpriteVersion::try_from(raw_version)
        .map_err(|_| PetLoadError::UnsupportedVersion(raw_version))?;
    let relative_path =
        nonempty(manifest.spritesheet_path).unwrap_or_else(|| "spritesheet.webp".to_owned());
    let unresolved_sheet = package_path.join(relative_path);
    let spritesheet_path = unresolved_sheet
        .canonicalize()
        .map_err(|_| PetLoadError::SpritesheetMissing)?;
    if !spritesheet_path.starts_with(&package_path) || spritesheet_path == package_path {
        return Err(PetLoadError::SpritesheetOutsidePackage);
    }
    let extension = spritesheet_path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if extension != "webp" && extension != "png" {
        return Err(PetLoadError::UnsupportedSpritesheetExtension(extension));
    }
    if !spritesheet_path.is_file() {
        return Err(PetLoadError::SpritesheetMissing);
    }
    match Atlas::load(&spritesheet_path, version) {
        Ok(_) => {}
        Err(error @ AtlasError::InvalidDimensions { .. }) => {
            return Err(PetLoadError::Atlas(error));
        }
        Err(_) => return Err(PetLoadError::UnreadableSpritesheet),
    }
    let fallback_id = package_path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("pet")
        .to_owned();
    let id = nonempty(manifest.id).unwrap_or(fallback_id);
    let display_name = nonempty(manifest.display_name).unwrap_or_else(|| id.clone());
    Ok(PetDescriptor {
        id,
        display_name,
        description: nonempty(manifest.description),
        version: raw_version,
        package_path,
        spritesheet_path,
    })
}

#[must_use]
pub fn scan_library(pets_path: &Path) -> PetScanResult {
    let entries = match fs::read_dir(pets_path) {
        Ok(entries) => entries,
        Err(error) => {
            return PetScanResult {
                valid: Vec::new(),
                invalid: vec![PetFailure {
                    id: path_id(pets_path),
                    message: error.to_string(),
                }],
            };
        }
    };
    let mut directories = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|file_type| file_type.is_dir()))
        .collect::<Vec<_>>();
    directories.sort_by_key(|entry| entry.file_name().to_string_lossy().to_ascii_lowercase());
    let mut valid = Vec::new();
    let mut invalid = Vec::new();
    let mut ids = HashSet::new();
    for entry in directories {
        let name = entry.file_name().to_string_lossy().into_owned();
        match load_package(&entry.path()) {
            Ok(pet) if ids.insert(pet.id.clone()) => valid.push(pet),
            Ok(pet) => invalid.push(PetFailure {
                id: name,
                message: format!("duplicate pet id {}", pet.id),
            }),
            Err(error) => invalid.push(PetFailure {
                id: name,
                message: error.to_string(),
            }),
        }
    }
    PetScanResult { valid, invalid }
}

fn nonempty(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let value = value.trim();
        (!value.is_empty()).then(|| value.to_owned())
    })
}

fn path_id(path: &Path) -> String {
    path.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("pets")
        .to_owned()
}
