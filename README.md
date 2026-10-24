# claude-plugins

Ehsan Khan's plugins for [Claude Code](https://code.claude.com), in one marketplace.

## Install

Add the marketplace once:

```bash
claude plugin marketplace add ehsan18t/claude-plugins
```

Then install any plugin from it by name:

```bash
claude plugin install <plugin>@ehsan18t
```

## Plugins

| Plugin | What it does | Start with |
|---|---|---|
| [Shikigami](plugins/shikigami) | Opus plans a feature and does the final review; cheap OpenCode models (DeepSeek, Muse Spark) implement and check each piece in parallel git worktrees. Cuts Opus usage on multi-part features. | `/shikigami:run` |

## Layout

```
.claude-plugin/marketplace.json   the catalog: every plugin and where it lives
plugins/<name>/                   one folder per plugin
  .claude-plugin/plugin.json      the plugin's manifest
  skills/, agents/, ...           its components
  README.md                       its documentation
```

## Adding a plugin

1. Create `plugins/<name>/` with a `.claude-plugin/plugin.json` and its components.
2. Add an entry to `.claude-plugin/marketplace.json` with `"source": "./plugins/<name>"`, using the same `name` as the manifest.
3. Run `claude plugin validate plugins/<name>`.
4. Add a row to the table above.

## License

MIT. See [LICENSE](LICENSE). Each plugin carries its own license file.
