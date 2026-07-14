fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").expect("Cargo supplies CARGO_MANIFEST_DIR");
    let output = std::path::Path::new(&crate_dir).join("../../include/petrunner_bridge.h");
    std::fs::create_dir_all(output.parent().expect("header has a parent"))
        .expect("create header directory");
    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_language(cbindgen::Language::C)
        .with_include_guard("PETRUNNER_BRIDGE_H")
        .generate()
        .expect("generate C bridge header")
        .write_to_file(output);
}
