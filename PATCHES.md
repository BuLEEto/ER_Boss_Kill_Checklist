# Local patches to vendored code

`vendor/skald/` is a copy of Skald, not a submodule. Anything changed here
has to be re-applied — or better, fixed upstream and re-vendored — or it
disappears the next time the copy is refreshed. This file is the list, so
that doesn't happen silently.

Each patch is marked in the source with a `LOCAL PATCH (see PATCHES.md)`
comment, so `grep -rn "LOCAL PATCH" vendor/` finds them all.

---

## 1. Nested-scroll wheel routing picks the innermost viewport by area

**File:** `vendor/skald/skald/view.odin`, in `scroll_advance`
**Test:** `vendor/skald/skald/scroll_stamp_order_test.odin`
**Upstream status:** not reported yet

### Symptom

The mouse wheel did nothing over the font picker's dropdown. The page
behind it scrolled instead.

### Cause

Only the innermost hovered scrollable is supposed to consume a wheel
delta. `scroll_advance` decided which one that was from the order
viewports had stamped themselves into `scroll_rects` last frame, taking
the *last* rect under the cursor:

```odin
for i := len(ctx.widgets.scroll_rects_prev) - 1; i >= 0; i -= 1 {
    cand := ctx.widgets.scroll_rects_prev[i]
    if rect_contains_point(cand.rect, ctx.input.mouse_pos) {
        claim_wheel = cand.id == id
        ...
```

That assumes stamps run outer → inner. They don't, when the outer scroller
is fill-mode. `scroll(ctx, {0,0}, ...)` defers through `sized`, so its
`scroll_advance` runs during layout — *after* an inner fixed-size scroll
that was built as one of its own arguments has already stamped. Odin
evaluates arguments before the call, so:

```odin
skald.scroll(ctx, {0, 0}, skald.col(..rows[:]))
//                        ^ combobox in here stamps first
// ^ this stamps second
```

The list reads inner → outer, the backwards scan finds the *outer* rect
first, and the inner scroller never claims. Any fixed-size scroller inside
a fill-mode one has a dead wheel — combobox and select dropdowns being the
ones you meet in practice, since both size their popup to `max_rows`.

### Fix

Pick the smallest viewport containing the cursor instead. Order-
independent, and needs no depth plumbing: nested viewports strictly
contain one another so the inner one is smaller, and siblings don't
overlap so at most one contains the point.

### Note for upstreaming

The two tests in `scroll_stamp_order_test.odin` cover both stamp orders.
Before the fix the inner-first one fails and the outer-first one passes;
after it, both pass. The rest of the suite (79 tests) is unaffected.
