use jeryu_runner_microvm::image_composition::inventory;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let root = arguments.next().ok_or("expected absolute staging root")?;
    if arguments.next().is_some() {
        return Err("expected one staging root".into());
    }
    inventory(std::path::Path::new(&root))?;
    Ok(())
}
