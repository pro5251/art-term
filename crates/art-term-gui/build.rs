fn main() {
    for name in [
        "ART_TERM_ENABLE_PRIVATE_RUNTIME_BOOTSTRAP",
        "ART_TERM_PRIVATE_RUNTIME_BOOTSTRAP_FILE",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
        assert!(
            std::env::var_os(name).is_none_or(|v| v.is_empty()),
            "private runtime bootstrap is retired; create or import connections in the App"
        );
    }
    tauri_build::build()
}
