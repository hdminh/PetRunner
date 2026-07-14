use std::path::Path;

use image::{DynamicImage, ImageFormat, ImageReader, RgbaImage};
use thiserror::Error;

use crate::animation::AtlasAddress;

pub const CELL_WIDTH: u32 = 192;
pub const CELL_HEIGHT: u32 = 208;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum SpriteVersion {
    V1 = 1,
    V2 = 2,
}

impl TryFrom<i32> for SpriteVersion {
    type Error = ();
    fn try_from(value: i32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(Self::V1),
            2 => Ok(Self::V2),
            _ => Err(()),
        }
    }
}

impl SpriteVersion {
    #[must_use]
    pub const fn row_count(self) -> u32 {
        if matches!(self, Self::V1) { 9 } else { 11 }
    }
    #[must_use]
    pub const fn expected_dimensions(self) -> (u32, u32) {
        (1536, self.row_count() * CELL_HEIGHT)
    }
}

#[derive(Debug, Error)]
pub enum AtlasError {
    #[error("spritesheet cannot be read: {0}")]
    Read(#[from] std::io::Error),
    #[error("spritesheet cannot be decoded: {0}")]
    Decode(#[from] image::ImageError),
    #[error("atlas is {actual_width}×{actual_height}; expected {expected_width}×{expected_height}")]
    InvalidDimensions {
        expected_width: u32,
        expected_height: u32,
        actual_width: u32,
        actual_height: u32,
    },
    #[error("atlas address is outside this sprite version")]
    InvalidAddress,
}

#[derive(Debug)]
pub struct Atlas {
    version: SpriteVersion,
    image: RgbaImage,
}

impl Atlas {
    pub fn load(path: &Path, version: SpriteVersion) -> Result<Self, AtlasError> {
        let reader = ImageReader::open(path)?.with_guessed_format()?;
        Self::from_dynamic(reader.decode()?, version)
    }

    pub fn from_dynamic(image: DynamicImage, version: SpriteVersion) -> Result<Self, AtlasError> {
        let actual_width = image.width();
        let actual_height = image.height();
        let (expected_width, expected_height) = version.expected_dimensions();
        if (actual_width, actual_height) != (expected_width, expected_height) {
            return Err(AtlasError::InvalidDimensions {
                expected_width,
                expected_height,
                actual_width,
                actual_height,
            });
        }
        Ok(Self {
            version,
            image: image.to_rgba8(),
        })
    }

    #[must_use]
    pub const fn version(&self) -> SpriteVersion {
        self.version
    }

    pub fn frame_png(&self, address: AtlasAddress) -> Result<Vec<u8>, AtlasError> {
        if address.row < 0
            || address.column < 0
            || address.row as u32 >= self.version.row_count()
            || address.column >= 8
        {
            return Err(AtlasError::InvalidAddress);
        }
        let frame = image::imageops::crop_imm(
            &self.image,
            address.column as u32 * CELL_WIDTH,
            address.row as u32 * CELL_HEIGHT,
            CELL_WIDTH,
            CELL_HEIGHT,
        )
        .to_image();
        let mut output = std::io::Cursor::new(Vec::new());
        DynamicImage::ImageRgba8(frame).write_to(&mut output, ImageFormat::Png)?;
        Ok(output.into_inner())
    }
}
