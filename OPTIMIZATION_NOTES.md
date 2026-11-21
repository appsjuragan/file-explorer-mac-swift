# Performance pass — what changed and why

Not compiled here (no macOS/Swift toolchain in this environment). All files pass a Swift
syntax parse; run `swift build && swift test` first.

## Biggest wins

| Problem (before) | Fix |
|---|---|
| Opening any folder started a recursive crawl (depth 4) of **every** subfolder, again on every FSEvents reload and app activation. Unbounded disk I/O, CPU, and an index that never shrank. | `FileIndexWorker` no longer crawls on load; it only records the listing it was given. Recursive work happens only for folder stats someone asked for, and for search. |
| Every Details cell (5 per row) built its tooltip on every reload/scroll. For folders that did a **synchronous directory scan on the main thread** (up to 40 ms + listing time) and spawned a depth-6 crawl. | Tooltips are lazy (`LazyToolTip`, an `NSViewToolTipOwner`): text is built on hover only. `folderStats(for:)` never touches the disk on the caller's thread. Visible folder rows prefetch stats in the background. |
| Background crawls ran as `Task.detached` on Swift's cooperative pool, blocking its threads with disk I/O and starving user-initiated work. Many ran at once. | One serial utility queue, newest request first, backlog capped at 24, each crawl capped at depth 6 / 3 s. |
| FSEvents streams are recursive: watching `~` reloaded the list on every write under `~/Library`. | `DirectoryWatcher` only reacts to the folder itself and its direct children (handles `/private`, firmlink and case differences), debounces 250 ms with a 1 s ceiling. |
| `queue.sync` per file inside crawls; search scanned the whole index while holding the lock, blocking the main thread. | `NSLock` held only for dictionary updates (one per directory); name matching happens outside the lock. |

## Also fixed along the way

- **Search correctness:** `hasPrefix(root)` matched sibling folders (`/a/foo` vs `/a/foobar`); results depended on whether a background crawl had finished. The index now answers only for subtrees it fully indexed in the last 60 s; otherwise disk is scanned.
- **Index memory:** capped at 100k entries; dead maps (`pathsByExtension`, `pathsByDirectory`) removed; deleted/renamed entries are pruned when a folder is re-listed, and their ancestors' stats invalidated.
- **Watcher crash risk:** `deinit` used a `[weak self]` async hop, which is always nil in deinit, so the stream (holding an unretained `self`) was never stopped.
- **Compile blocker:** the old search fallback mutated captured `var`s inside a `@Sendable` closure.
- **Progress:** `ProgressThrottle` (shared by copy/move and compress) caps main-actor hops to ~20/s; previously 2 per file.
- **Process output:** lines are split on bytes, so a UTF-8 character split across reads no longer drops the whole chunk; streamed stdout is no longer buffered in memory; a failed launch no longer leaks a blocked reader thread.
- **Model:** `indexByPath` makes `selectedItems`, `item(at:)`, type-ahead and selection pruning O(selection) instead of O(folder) (StatusBar, CommandBar and PreviewPane call these on every render). Re-sorting folders over 2,000 items runs off the main thread; a load that finishes after a sort change is re-laid-out with the current settings.
- **Ordering:** start-of-day computed once per grouping pass instead of per item; static `URLResourceKey` sets and copy-name regex instead of rebuilding per call.
- **DRY:** one `FileSystemService.walk` used by both searches; `FileIndexEntry` (a copy of `FileItem`) removed; tooltip/MIME code moved to `UI/FileList/FileTooltips.swift`.

## Behaviour changes to be aware of

- Folder tooltips show `+` after size/count when the scan hit its depth/time limit.
- Search no longer descends into `.app` bundles (they still match by name).
- `ProcessRunner.runStreaming` returns empty `stdout` when a line handler is given.

## Not changed (noted)

- `tar -v` (tar.gz / 7z) writes its file list to **stderr**, so compress progress only advances for zip. Pre-existing.
- `localizedStandardCompare` still dominates name sorting of very large folders (now off the main thread).
