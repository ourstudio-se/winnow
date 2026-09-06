# kdl (vendored)

Vendored copy of [kdl-zig](https://github.com/AnimeCatGirlIndustries/kdl-zig) v0.0.4
(MIT, see LICENSE), patched for Zig 0.16 compatibility.

Upstream has no Zig 0.16 release and its build scripts (bench/fuzz/tests) don't
compile under 0.16, which breaks any project that depends on it via URL — the
build runner compiles the whole dependency build.zig. So we vendor just `src/`
with our own minimal build.zig that exposes the `kdl` module.

Local changes vs upstream v0.0.4:
- `std.ArrayListUnmanaged(T){}` / `.{}` inits replaced with `.empty` (Zig 0.16
  removed default field values on array lists).
- Any further 0.16 std API fixes as needed.

If upstream ships a 0.16-compatible release, this directory can be deleted and
replaced with a normal URL dependency in `build.zig.zon`.
