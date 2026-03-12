# CBUF_INIT_SIZE == 0 Support Design

**Date:** 2026-03-11

## Goal
Allow `cbuf` to work correctly when `CBUF_INIT_SIZE == 0` under C99/C11 without invoking undefined behavior (no `char b[0]`). Keep the public API unchanged while permitting `struct cbuf` to omit the inline buffer member.

## Non-Goals
- Refactor or replace `lbuf` in `llogger.c` (this is a follow-up use-case, not part of this change).
- Change allocation semantics or introduce new error handling paths.

## Approach
1. **Introduce `CBUF_BASE(b)` macro**
   - When `CBUF_INIT_SIZE == 0`, `CBUF_BASE(b)` expands to `NULL`.
   - Otherwise it expands to `b->b`.

2. **Conditionally include the inline buffer member**
   - `struct cbuf` defines `char b[CBUF_INIT_SIZE];` only when `CBUF_INIT_SIZE > 0`.
   - This avoids `char b[0]` UB in C99/C11.

3. **Update internal logic to use `CBUF_BASE(b)`**
   - `cbuf_init`: `data = CBUF_BASE(b)`, `len = 0`, `cap = CBUF_INIT_SIZE`.
   - `cbuf_free`: treat inline buffer as `CBUF_BASE(b)`; only free when `data != NULL && data != CBUF_BASE(b)`.
   - `cbuf_ensure`: handle `cap == 0` by allocating on first growth. Copy from inline buffer only if `CBUF_BASE(b) != NULL` and `data == CBUF_BASE(b)`.

## Data Flow (CBUF_INIT_SIZE == 0)
- Init: `data = NULL`, `cap = 0`.
- First `ensure`: allocate heap buffer, no inline copy.
- Subsequent ensures: `realloc` as usual.

## Edge Cases
- `CBUF_INIT_SIZE == 0` with zero-length growth: no allocation until needed.
- `CBUF_INIT_SIZE > 0`: behavior matches existing code.

## Testing
- Build-only verification is sufficient for this change.
- Optional follow-up: adjust `llogger` to use `cbuf` and run existing tests.
