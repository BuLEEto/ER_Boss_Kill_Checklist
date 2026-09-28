# Vendored: http

Upstream: `~/odin/libs/http/` (Lee's own library, not a third party).

## Why this file exists

This copy is **not** verbatim. It carries local patches, and a re-vendor
that simply overwrites `http.odin` will silently drop them — reintroducing
a bug that took a full session to find the first time. Re-apply them, or
land them upstream first and then re-vendor.

Check before and after any refresh:

```sh
diff -u ~/odin/libs/http/http.odin src/libs/http/http.odin
```

## Local patches

### 1. Path guards that work on Windows

Upstream treats a backslash as an attempted escape and compares paths by
POSIX rules. On Windows `filepath.clean` and `os.stat().fullpath` both
return `\` separators, so every file one directory down read as an escape
attempt and the app died at startup with

    Could not load templates/overlay.html: File_Not_Found

Three changes:

- `local_path_is_unsafe` — a separate guard for local filesystem paths,
  which rejects NUL everywhere but only rejects `\` off Windows.
  `path_contains_unsafe_chars` keeps its old behaviour for URL fragments.
  `template_load` and `serve_static_file` use the new one.
- `path_comparison_form` — folds `\` to `/` and lowercases on Windows
  (NTFS is case-insensitive), used by `path_is_within_root_resolved`.
- The static handler's escape check also catches a backslash `..\`.

Without the second change every file under `/static/` would have 404'd.
That one was only found by running the .exe, not by reading the code.

### 2. Static assets are not cached

Upstream sends `Cache-Control: public, max-age=86400` for CSS, JS, images
and fonts. Correct for a public web server; wrong for this one.

The client that matters is OBS's embedded browser, which keeps a disk
cache across restarts. A day-old stylesheet outlives an app upgrade and the
overlay then renders against CSS that no longer matches its HTML — the
user sees a broken overlay with no reason to suspect a cache, and the only
fix from their side is "Refresh cache of current page" in the source
properties. Reported from a real stream setup.

Everything served is a few KB over loopback, so caching bought nothing
here in the first place. Now sends `no-store, no-cache, must-revalidate`.

The router's own routes are covered separately by the `no_store`
middleware in `server.odin`, because static files are served before the
middleware chain runs.
