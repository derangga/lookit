# Resources

`AppIcon.iconset/` — the app icon, in the layout `iconutil` expects.
`scripts/bundle.sh` compiles it to `Contents/Resources/AppIcon.icns` on every
build, so there is no `.icns` committed and no way for one to drift from the art.

Where it shows: Finder, System Settings > Login Items, the Open dialog. **Not
the Dock** — lookit is `LSUIElement`. **Not the menubar** either: that image is
an SF Symbol set in `main.swift`, deliberately, because a template image inverts
with the menubar and a colour icon would not.

## Replacing it

The ten slots are five sizes at 1× and 2×, so each bitmap is used twice:

| slot | pixels |
|---|---|
| `icon_16x16` / `icon_16x16@2x` | 16, 32 |
| `icon_32x32` / `icon_32x32@2x` | 32, 64 |
| `icon_128x128` / `icon_128x128@2x` | 128, 256 |
| `icon_256x256` / `icon_256x256@2x` | 256, 512 |
| `icon_512x512` / `icon_512x512@2x` | 512, 1024 |

Drop in replacements at those exact names and rebuild. `iconutil` rejects the
set if a name or a dimension is wrong, so a mistake fails the build rather than
shipping a broken icon.

The current art came from an appicon.co pack, generated into an untracked
`AppIcons/` folder and mapped in here once. That folder is gitignored and is not
needed to build.
