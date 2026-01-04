# Entropy Shield New Requests

We’re seeing massive memory growth during repeated `par2_create_*` usage from the app (500k+ files); queue is bounded and parity blobs are written to SQLite, so this looks like a leak or persistent allocator growth inside par2-cleanroom.

Please investigate and report:
- Whether `par2_create_new` → `par2_create_add_path`/`par2_create_add_memory` → `par2_create_run` → `par2_create_destroy` leaks memory when called in a tight loop.
- Whether output callbacks (`par2_create_set_output_open` + write/close) leave any retained buffers when `par2_create_run` returns successfully or fails.
- Whether any global caches/allocators are retaining memory across runs (especially with multithreaded creation).
- If you find a leak, please fix and add a regression test.

If no leak is found, please confirm and note the peak resident size per run on a synthetic test (e.g., 10k small files in a loop).

Optional (nice-to-have):
- If you can expose an API to stream parity outputs in chunks (to avoid fully materializing them in memory), document it; we may use it for SQLite-backed stores.
