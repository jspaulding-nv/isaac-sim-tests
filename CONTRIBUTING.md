# Contributing

Contributions that improve reproducibility, portability, validation or result
interpretation are welcome.

Before opening a pull request:

1. Keep image versions and workload parameters explicit.
2. Do not commit `.env`, `output/`, raw machine inventories, checkpoints, or
   private media.
3. Run `./scripts/audit_public_tree.sh`.
4. Run `bash -n` over modified shell scripts and compile-check modified Python.
5. Describe the GPU, driver, image digest, task, scale, seeds, and limitations
   for any new result.

Do not present a single-system result as official certification or universal
hardware support.
