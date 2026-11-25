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

## Links

- Guide: [How to add analytics to a Godot game](https://manalens.dev/blog/godot-analytics)
- Docs: [docs.manalens.dev](https://docs.manalens.dev)
- Support: [manalens.dev/support](https://manalens.dev/support)

## License

MIT. See [LICENSE](LICENSE).
