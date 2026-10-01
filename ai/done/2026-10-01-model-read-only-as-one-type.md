# Model read-only mode as one type

`/api/config` returns `"message": "Generation is temporarily disabled."` even
with `"readOnly": false`; seen on orchid. Harmless (`app.js` shows the banner
only when `readOnly` is set), but it reports a message for a state the server
is not in. Two causes:

- `Config` carries `cfgReadOnly :: Bool` and `cfgReadOnlyMsg :: Text`
  separately, so the message exists whether or not generation is disabled.
- The default text is stated three times: `readOnlyMessage` in
  `nix/module.nix`, the `PLAYGROUND_READONLY_MESSAGE` fallback in
  `app/Main.hs`, and the `cfg.message ||` fallback in `static/app.js`.

## Fix

- `Main.hs`: replace both fields by one, e.g. `data Generation = Enabled |
  Disabled Text`, built from the two env variables; the default text lives
  only here. `/api/config` sends the message only when disabled.
- `app.js`: drop its fallback text and show the server's message.
- `module.nix`: make `readOnlyMessage` `nullOr str`, default `null`, and set
  `PLAYGROUND_READONLY_MESSAGE` only when it is non-null.
- README env table and `nix/test.nix`: add a check that `/api/config` has no
  message while generation is enabled.

Open: the JSON shape. Either keep `readOnly` and omit `message` when it is
false (the frontend needs no change beyond the fallback), or replace both by
`"readOnly": null | "<message>"`, which mirrors the type but breaks clients
that read `readOnly` as a boolean.

Resolved: `"readOnly": null | "<message>"`. `app.js`'s truthiness check
survives the change, so the server treats an empty
`PLAYGROUND_READONLY_MESSAGE` as unset rather than send `""`.
