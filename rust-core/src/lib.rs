// uniffi's generated scaffolding (included below) emits doc comments
// followed by blank lines, which trips this clippy lint on code we
// can't edit. Scope-allow it for the crate.
#![allow(clippy::empty_line_after_doc_comments)]

mod ffi;
mod serato;
mod tags;

pub use ffi::*;

uniffi::include_scaffolding!("crate-agent-core");
