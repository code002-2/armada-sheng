//! RGB lighting support for Armada devices.

mod backend;
mod config;
mod controller;
mod correction;
#[path = "rgb-saturation.rs"]
mod rgb_saturation_helper;
mod runtime;
mod state;

pub use backend::{ChannelBackend, LightingBackend, MulticolorBackend};
pub use controller::Controller;
pub use correction::ColorCorrection;
pub use state::LightingConfig;
