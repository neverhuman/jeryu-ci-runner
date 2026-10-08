fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!(
        "{}",
        serde_json::to_string_pretty(&jeryu_runner_protocol::wire::v2::schema())?
    );
    Ok(())
}
