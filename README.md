# Manalens for Godot 4

Game analytics for Godot 4 in plain GDScript, with no native code. The addon sends sessions, `game_open`, your game events, and errors to [Manalens](https://manalens.dev) with your project Publishable key. It keeps an offline queue on disk and has a consent mode.

It works on every export target that has `HTTPRequest`: Windows, macOS, Linux, Android, iOS, and Web.

## Install

1. Copy `addons/manalens` into the `addons/` folder of your project.
2. Open **Project > Project Settings > Plugins** and enable **Manalens**. This adds the `Manalens` autoload.
3. Call `Manalens.init()` once, for example in the `_ready()` of your first scene.

```gdscript
func _ready() -> void:
    Manalens.init({
        "publishable_key": "YOUR_PUBLISHABLE_KEY",
        "endpoint": "https://YOUR_COLLECTOR_ENDPOINT",
        "app_version": "1.4.0",
        "storefront": "steam",
    })
```

The full API, the options, and how the queue, sessions, consent, and errors work are in [`addons/manalens/README.md`](addons/manalens/README.md).

## Repository layout

| Path | What it is |
| --- | --- |
| `addons/manalens/` | The addon. This is the only folder your game needs. |
| `test_project/` | A Godot project that runs the addon against a collector. It is not in the Asset Library download. |
| `test_project/run-tests.mjs` | The tests that need no network: the request fixtures and the offline modes. `GODOT=/path/to/godot node test_project/run-tests.mjs` (Godot 4.5 or later, Node 20 or later). |
| `.github/workflows/` | CI (`ci.yml`) runs the tests above on each pull request. `release.yml` makes a release from a `v*` tag. |

## Releases

Each [release](https://github.com/manalens/manalens-godot/releases) has `manalens-godot-<version>.zip` (the `addons/manalens` folder, `LICENSE`, `README.md`, and `CHANGELOG.md`), `SHA256SUMS`, and the changes from `CHANGELOG.md`. GitHub Actions builds the zip from the tagged commit and attests its build provenance. To check a download:

```bash
sha256sum --check --ignore-missing SHA256SUMS
gh attestation verify manalens-godot-<version>.zip --repo manalens/manalens-godot
```

## Links

- Guide: [How to add analytics to a Godot game](https://manalens.dev/blog/godot-analytics)
- Docs: [docs.manalens.dev](https://docs.manalens.dev)
- Support: [manalens.dev/support](https://manalens.dev/support)

## License

MIT. See [LICENSE](LICENSE).
