use crate::{Error, Result};
use rudof_lib::{RudofConfig, TomlConfig};
use serde_json::Value;
use std::path::Path;

pub fn load(source: &str) -> Result<RudofConfig> {
    let options: Value = serde_json::from_str(source).map_err(Error::invalid)?;
    if let Some(path) = options.get("path").and_then(Value::as_str) {
        return RudofConfig::from_path(Path::new(path)).map_err(Error::invalid);
    }
    let text = match options.get("toml_str").and_then(Value::as_str) {
        Some(text) => text.to_owned(),
        None => toml::to_string(options.get("config").unwrap_or(&serde_json::json!({})))
            .map_err(Error::invalid)?,
    };
    RudofConfig::from_toml_str(&text).map_err(Error::invalid)
}
