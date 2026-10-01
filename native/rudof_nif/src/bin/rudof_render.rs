//! Run upstream external renderers outside BEAM's SIGCHLD/reaping machinery.
use rudof_lib::{Rudof, RudofConfig, formats::*};
use serde_json::Value;
use std::{error::Error, fs};

fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        return Err("expected snapshot and output filenames".into());
    }
    let snapshot: Value = serde_json::from_slice(&fs::read(&args[0])?)?;
    let mut config: RudofConfig = serde_json::from_value(snapshot["config"].clone())?;
    config.resolve();
    let mut r = Rudof::new(config);
    let source = snapshot["source"].as_str().ok_or("missing source")?;
    let format = snapshot["format"].as_str().ok_or("missing format")?;
    let engine = snapshot["engine"].as_str().unwrap_or("plantuml").parse()?;
    let input = InputSpec::str(source);
    let mut output = Vec::new();
    if snapshot["kind"] == "data" {
        r.load_data()
            .with_data(&[input])
            .with_data_format(&DataFormat::Turtle)
            .execute()?;
        r.serialize_data(&mut output)
            .with_result_data_format(&format.parse()?)
            .with_viz_engine(&engine)
            .execute()?;
    } else if snapshot["kind"] == "conversion" {
        // Delegate the actual UML conversion, preserving its shape-selection and
        // timing semantics rather than substituting the schema serializer.
        let format = format.parse()?;
        let mut b = r
            .show_schema_conversion(
                &input,
                &ConversionMode::ShEx,
                &ResultConversionMode::Uml,
                &ConversionFormat::ShExJ,
                &format,
                &mut output,
            )
            .with_viz_engine(&engine);
        let opts = &snapshot["options"];
        if let Some(v) = opts["shape"].as_str() {
            b = b.with_shape(v);
        }
        if let Some(v) = opts["show_time"].as_bool() {
            b = b.with_show_time(v);
        }
        b.execute()?;
    } else {
        r.load_shex_schema(&input)
            .with_shex_schema_format(&ShExFormat::ShExJ)
            .execute()?;
        let format = format.parse()?;
        let mut b = r
            .serialize_shex_schema(&mut output)
            .with_result_shex_format(&format)
            .with_viz_engine(&engine);
        let opts = &snapshot["options"];
        if let Some(v) = opts["shape"].as_str() {
            b = b.with_shape(v);
        }
        if let Some(v) = opts["show_schema"].as_bool() {
            b = b.with_show_schema(v);
        }
        if let Some(v) = opts["show_statistics"].as_bool() {
            b = b.with_show_statistics(v);
        }
        if let Some(v) = opts["show_dependencies"].as_bool() {
            b = b.with_show_dependencies(v);
        }
        if let Some(v) = opts["show_time"].as_bool() {
            b = b.with_show_time(v);
        }
        b.execute()?;
    }
    fs::write(&args[1], output)?;
    Ok(())
}
