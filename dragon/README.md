# `dragon/` — DragonMax's own code

Everything Snapdragon-specific that is *not* an edit to Modular's tree lives
here, so the fork's diff against `winmojo/main` stays legible.

| Path | Contents |
|---|---|
| `recon/` | Measured facts about the hardware and about MAX's structure |
| `probe/` | Standalone harnesses that drive each compute surface directly |

Edits that *must* live in Modular's tree — new targets in
`mojo/stdlib/std/gpu/host/info.mojo`, Snapdragon kernel variants under
`max/kernels/src/` — stay in place there rather than being mirrored here.
