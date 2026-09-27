# Performance: measured costs and what was fixed

Every number here was measured on this machine with `vim.uv.hrtime()` around the
real code paths, not estimated. Re-run the measurements with the probe style shown
at the end if you change the scanners.

## What was wrong

### 1. `vim.wait` used as a courtesy yield (the big one)

The synchronous analysis paths yielded to the event loop between batches with
`vim.wait(1, function() return false end)`. The intent was "give the UI 1 ms to
redraw". The reality:

| | before | after |
|---|---|---|
| `static.all_deps` (8-file project) | **534 ms** | **2 ms** |
| of which spent inside `vim.wait` | **3052 ms** (3 calls) | 0 |
| actual scanning work | 2 ms | 2 ms |

Three `vim.wait` calls cost about one second each. `vim.wait` services the event
loop while it waits, so its timeout is a floor rather than a ceiling: with work
pending it can overshoot by orders of magnitude. A 1 ms request turned into ~1000 ms.

The fix is removal, not a smaller timeout. Nothing between batches needs the loop —
it is plain Lua plus file reads. Callers that need a responsive UI pass an `on_done`
callback and get the genuinely chunked timer path, which is unchanged.

**Rule for this codebase:** never call `vim.wait` to "yield". Use it only when
there is a real predicate to wait for (`vim.wait(timeout, function() return done end)`)
and the work is happening off the main thread. To yield, use a timer.

### 2. Tree-sitter probing repeated per file

`try_treesitter` loaded the parser and probed every candidate capture for **each
file**, then fell back to the regex pass. When a grammar exists but the query
cannot be built — Fortran here — the entire cost was wasted, and that is a
permanent condition for the session.

| | before | after |
|---|---|---|
| `extract_file` per file | **8.06 ms** | **0.67 ms** |
| `extract_symbols` regex-only reference | 0.11–0.22 ms | — |

The decision is now cached per language, including the negative result. Symbol
extraction output is unchanged (verified: `module`, `function`, `subroutine` all
still found in the fixture).

## Current costs

Small project (8 files, Fortran + C + Python):

| stage | cost |
|---|---|
| `scan.collect` | 3–5 ms |
| `extract_file`, all files | 78 ms cold, ~5 ms warm |
| `static.all_deps` | 2 ms |
| `call_graph` | < 1 ms |
| `context.build` (paid on every prompt) | 8–9 ms |

Larger tree (53 files, mixed): `scan.collect` 86 ms, the rest in single digits.

## Where the remaining cost is, and what to do about it

**`scan.collect` is I/O bound and scales with file count.** It reads every file
once to count lines. On a 53-file tree that is 86 ms; on a 10k-file tree expect
seconds. Levers, in order of value:

1. Narrow the target. Analysing a file or one subdirectory is the single biggest
   win, and it is why `:DshTree <path>` takes an explicit target.
2. Raise the ignore list. `build/`, `_build/`, `.venv/`, generated sources and
   vendored trees dominated the scan on real projects. `scan.IGNORE_DIRS` is the
   place to add project-specific noise.
3. `max_files` caps the work; the analysis reports when it truncated.

**Symbol extraction is regex-bound, roughly linear in bytes.** At 0.67 ms per file
the practical ceiling is a few thousand files before a synchronous run becomes
noticeable. `extract_project_async` exists for that case and chunks on a timer.

**The same project is analysed repeatedly.** `:DshTree`, `:DshProjectTree` and
`:DshAnalyze` each walk the tree independently, and nothing is cached between
them. This is the clearest remaining optimisation: one cached scan plus one cached
symbol table, keyed by root and invalidated on write, shared by all three. It is
not implemented because cache invalidation needs care (a stale symbol table is
worse than a slow one), and the measured cost is currently small enough that the
risk is not yet worth taking.

**`context.build` costs 8–9 ms on every prompt.** It is dominated by the LSP
symbol request, which has a 600 ms deadline but normally returns immediately.
That cost is per request, not per file, so it does not grow with project size.

**Memory.** Symbol tables are held per file for the life of an analysis. A very
large tree holds a lot of small tables; the async paths release them when the run
finishes, and `project_tree` keeps only its own index.

## Measuring a change

```lua
local t = vim.uv.hrtime()
-- work
print(('%.1f ms'):format((vim.uv.hrtime() - t) / 1e6))
```

For anything that yields, wrap `vim.wait` to count calls and time spent inside it —
that is how the first problem above was found:

```lua
local real = vim.wait
vim.wait = function(...)
  local t0 = vim.uv.hrtime()
  local a, b, c = real(...)
  total = total + (vim.uv.hrtime() - t0)
  return a, b, c
end
```

A stage that reports "fast when timed in isolation, slow in practice" is almost
always waiting on the event loop rather than doing work. Time inside the wait
separately from total elapsed time before concluding that the scanning code is
slow.
