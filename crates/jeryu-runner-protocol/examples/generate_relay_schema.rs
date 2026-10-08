fn main() -> Result<(), serde_json::Error> {
    println!(
        "{}",
        serde_json::to_string_pretty(&jeryu_runner_protocol::relay::schema())?
    );
    Ok(())
}
