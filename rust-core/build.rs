fn main() {
    uniffi::generate_scaffolding("src/crate-agent-core.udl")
        .expect("uniffi scaffolding generation");
}
