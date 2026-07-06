# Community Package Recipe

This recipe follows Modular's current rattler-build packaging guide and pins an immutable source commit and exact Mojo compiler. One package installs the `json`, `msgpack`, `bson`, and `cbor` Mojo modules because the binary front-ends share the public JSON tape contract.

Build it locally against the nightly compiler channel:

```bash
rattler-build build \
  --recipe conda.recipe/recipe.yaml \
  -c conda-forge \
  -c https://conda.modular.com/max-nightly \
  -c https://repo.prefix.dev/modular-community
```

The `modular-community` repository currently builds against `https://conda.modular.com/max`, not `max-nightly`. Submit this recipe after Mojo `1.0.0b3` reaches the stable channel, replacing `mojo_version` with the released compiler version and keeping the full source SHA.
