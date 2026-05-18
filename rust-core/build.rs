fn main() {
    uniffi::generate_scaffolding("./crate-agent-core.udl").expect("uniffi scaffolding generation");
}
