use jeryu_runner_microvm::image_composition::compose;
use jeryu_runner_protocol::wire::v2::RuntimeImageClass;
use std::{path::PathBuf, process::ExitCode};

fn main() -> ExitCode {
    let mut arguments = std::env::args_os().skip(1);
    let image_class = match arguments.next().as_deref() {
        Some(value) if value == "production" => RuntimeImageClass::Production,
        Some(value) if value == "test" => RuntimeImageClass::Test,
        _ => return reject(),
    };
    let Some(staging_root) = arguments.next() else {
        return reject();
    };
    if arguments.next().is_some() || compose(&PathBuf::from(staging_root), image_class).is_err() {
        return reject();
    }
    println!(
        "runtime_class_composed={}",
        match image_class {
            RuntimeImageClass::Production => "production",
            RuntimeImageClass::Test => "test",
        }
    );
    ExitCode::SUCCESS
}

fn reject() -> ExitCode {
    eprintln!("runtime_class_composition_failed");
    ExitCode::FAILURE
}
