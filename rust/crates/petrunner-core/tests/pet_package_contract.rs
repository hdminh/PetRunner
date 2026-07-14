use std::fs;

use image::{ImageBuffer, Rgba};
use petrunner_core::{SpriteVersion, scan_library};
use tempfile::tempdir;

fn write_pet(root: &std::path::Path, name: &str, manifest: &str, height: u32) {
    let directory = root.join(name);
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join("pet.json"), manifest).unwrap();
    let atlas = ImageBuffer::<Rgba<u8>, Vec<u8>>::new(1536, height);
    atlas.save(directory.join("spritesheet.png")).unwrap();
    atlas.save(directory.join("spritesheet.webp")).unwrap();
}

#[test]
fn scan_keeps_valid_versions_and_reports_invalid_packages() {
    let temporary = tempdir().unwrap();
    write_pet(temporary.path(), "default-pet", "{}", 1872);
    write_pet(
        temporary.path(),
        "v2-pet",
        r#"{"spriteVersionNumber":2,"spritesheetPath":"spritesheet.png"}"#,
        2288,
    );
    write_pet(temporary.path(), "wrong-size", "{}", 100);
    fs::create_dir(temporary.path().join("escape")).unwrap();
    fs::write(
        temporary.path().join("escape/pet.json"),
        r#"{"spritesheetPath":"../default-pet/spritesheet.png"}"#,
    )
    .unwrap();

    let result = scan_library(temporary.path());

    assert_eq!(result.valid.len(), 2);
    assert_eq!(result.valid[0].id, "default-pet");
    assert_eq!(result.valid[0].sprite_version(), SpriteVersion::V1);
    assert_eq!(result.valid[1].sprite_version(), SpriteVersion::V2);
    assert_eq!(result.invalid.len(), 2);
}
