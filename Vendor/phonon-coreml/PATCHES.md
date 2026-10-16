# Changes from upstream

Upstream: [fermionresearch/phonon-coreml](https://github.com/fermionresearch/phonon-coreml) 1.1.2 (commit `bf59e57`),
Apache License 2.0, © 2026 Fermion Research. `LICENSE` and `NOTICE` are upstream's, unchanged.

Vendored here so Yapr builds as a universal app (Apple silicon and Intel):

- `Sources/PhononCoreML/Transcriber.swift`: Swift's `Float16` is unavailable on Intel Macs, so the three places that
  read or write half-precision Core ML arrays now use `UInt16` storage and Accelerate's
  `vImageConvert_PlanarFtoPlanar16F` / `vImageConvert_Planar16FtoPlanarF`, which produce the same values.
- `Package.swift`: only the `PhononCoreML` library and its `PhononTDT` binary target (which already ships an
  `x86_64` slice) are kept; the command-line tools, example and tests are left out.

Everything else is upstream's code as released.
