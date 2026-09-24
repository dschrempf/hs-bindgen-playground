# Sync the talk examples with the deck: `OOPS` macro, `--omit-field-prefixes`

Handoff from the talk repository
(`~/talks/5-Well-Typed/2026-09-24-Vienna-Haskell-Meetup-HsBindgen`), where the
slides changed on 2026-09-24. The talk's slides must match what the playground
shows live.

## 1. Replace `TWO_G` in `examples/08-talk-villain.h`

```diff
 #define MASK (1u << 31)
-#define TWO_G (2 * 1024 * 1024 * 1024)
+#define OOPS (1 << 31)
```

`MASK`/`OOPS` now show both points (the `u` suffix types it as `CUInt`; the
plain literal is `CInt` and overflows) in one symmetric pair. The old `tWO_G`
listing took five lines of nested `(C.Expr.HostPlatform.*)`. Generated with the
playground's arguments, the new macro becomes:

```haskell
oOPS :: BG.CInt
oOPS =
  (C.Expr.HostPlatform.<<) (1 :: BG.CInt) (31 :: BG.CInt)
```

## 2. Demo `07-talk-nice.h` and `08-talk-villain.h` with `--omit-field-prefixes`

The slides now show fields without prefixes (`Vector { x, y }`,
`Blinds { window_id, tilt, ... }`, `Surname { len }`). `--omit-field-prefixes`
is already in `allowedOpts`, so it can be typed into the extra-options field
during the demo. Consider whether the two talk examples should preselect it,
so the demo cannot forget it.
