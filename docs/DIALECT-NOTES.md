# Dialect notes: writing Mojo 1.1 as this compiler actually accepts it

Working notes, not a manual. Every entry here was paid for with a real
compiler error or a real silent misbehaviour during the port, and each one
states the wrong spelling, the right spelling, and — where there is one — the
error text you will be staring at, so this file can be found by grepping the
diagnostic.

Companion documents: [LANGUAGE-DRIFT.md](LANGUAGE-DRIFT.md) is the list of
constructs the public documentation teaches and this compiler rejects;
[win32_posix_shim.md](win32_posix_shim.md) covers the POSIX layer. This file
is the positive counterpart: how to write the thing that works.

When these notes and the standard library disagree, the standard library is
right — `mojo/stdlib/std` is the largest body of Mojo known to compile
against this exact compiler, and grepping it for a working example is the
fastest way to settle any question here.

---

## Functions

**Everything is `def`.** `fn` is removed — *"'fn' has been removed; use
'def' instead"* — and it is still a reserved word, so `var fn = ...` is a
parse error too. Name variables holding callables `proc`, `entry`, anything
else.

**`def` does not imply `raises`.** A function that calls anything raising
must say so: `def main() raises:`. Error text: *"cannot call function that
may raise in a context that cannot raise"*.

**Compile-time constructs are spelled `comptime`.** `comptime x = ...` where
old code says `alias`; `comptime if` / `comptime for` where old code says
`@parameter if` / `@parameter for`; `comptime assert cond, "msg"` for static
assertions. The stdlib uses `comptime` 3,361 times and `alias` 51 — the
migration is done, write the new spelling.

---

## Value lifecycle: copy, move, destroy

None of the dunder names the public docs teach exist here. The Copyable and
Movable traits define the actual contract:

```mojo
struct Foo(Copyable, Movable):
    var x: Int

    def __init__(out self, *, copy: Self):        # copy constructor
        self.x = copy.x

    def __init__(out self, *, deinit move: Self): # move constructor
        self.x = move.x

    def __deinit__(deinit self):                  # destructor
        ...
```

- `__copyinit__` / `__moveinit__`: not in this dialect.
- `__del__`: deprecated — *"'__del__' is deprecated; use '__deinit__'"*.
- `deinit move` means the source is consumed **without its destructor
  running**. This is what makes a move genuinely free: ComPtr's move neither
  AddRefs nor Releases, and the refcount test proves it.
- Explicit copy is `value.copy()`; transfer is `value^`.

**After `value^`, the name is dead.** Using it again is *"use of
uninitialized value"*. If you need the value after handing it to a
`var`-parameter, pass it without `^` (which copies) and keep the original.

**ASAP destruction is real.** A value dies at its last use *by name*.
Passing `Pointer(to=x)` with its true origin counts as a use and keeps `x`
alive through the call — one more reason the origin rules below matter.

---

## Origins (the one that cost a day)

Full story in the journal ("Origins, or: three bugs that were one lie") and
the side-by-side proof in `examples/win32/structptr.mojo`. The rules:

1. **Variadic calls: true origin, no cast.**
   `external_call["clock_gettime", Int32](id, Pointer(to=ts))` — the origin
   is inferred, the aliasing is visible, the callee's writes land. This is
   the stdlib's own idiom at every libc boundary.

2. **Declared signatures: AnyOrigin, and cast to match at the call site.**
   There is no implicit origin conversion, so a declared
   `Pointer[T, MutAnyOrigin]` parameter needs
   `Pointer(to=x).unsafe_origin_cast[MutAnyOrigin]()` at the call. AnyOrigin
   keeps the aliasing ("might access any memory value").

3. **UntrackedOrigin is only for memory that is not Mojo's** — interface
   pointers, `alloc()` results, anything Windows hands back. Casting a
   local's pointer to Untracked tells the checker the pointer does *not*
   alias the local; the compiler may then hand the callee a temporary. It
   sometimes works anyway, which is worse than never working.

4. **`unsafe_origin_cast` preserves mutability.** You cannot cast a mutable
   pointer to an immutable origin — *"value passed to 'target_origin' cannot
   be converted from 'ImmOrigin' to 'MutOrigin'"*. For a `const` C parameter
   reached from mutable Mojo memory, spell the signature `MutAnyOrigin`
   anyway; the ABI is identical.

---

## FFI

**By name, variadic:** `external_call["symbol", Ret](args...)`. The symbol
must exist at link time or the whole binary fails to link, not the one call.

**Typed function pointers:** the C-ABI type is

```mojo
def (ArgType, ...) thin abi("C") -> Ret
```

- `thin` is required for the type to be `TrivialRegisterPassable` — without
  it: *"'com_method' parameter 'Sig' has 'TrivialRegisterPassable' type, but
  value has type 'AnyTrait[def(...) abi(\"C\") -> ...]'"*.
- **Spell every argument.** An under-declared signature compiles and then
  corrupts the call silently. This is the standing warning from the FFI
  docstrings and it has teeth.

**Address → callable:** `Pointer(to=entry).unsafe_bitcast[Sig]()[]` where
`entry` is an `Int` holding the function address. This is how the COM
dispatcher and `Win32Module.function` work.

**`OwnedDLHandle.get_function[Ret]("name")`** returns a `_DLCallable` —
variadic, origin-inferring, and it keeps the library alive until the call.
Prefer it for plain calls; use the bitcast path only when you need a typed
signature (COM, stored callables).

**`OwnedDLHandle` frees on drop.** For Win32 modules use
`Win32Module("user32.dll")` (std.sys._win32), which goes through the
process-lifetime cache and never frees.

**Callbacks out of Mojo** (C calling back in): top-level non-capturing
`def`, `@export("name", ABI="C")`, must not `raises` — catch inside. State
travels through the API's `void *user_data` slot, heap-allocated if the OS
holds it past the registering call.

---

## Structs at the ABI boundary

**Layout is C-compatible.** Declaration order, natural alignment. Verified
by probe: a `{u32, u32, i64, i32}` struct lands fields at 0/4/8/16 exactly
as C does. Check anyway — `comptime assert size_of[T]() ==
winkb_struct_size["T"]()` makes a disagreement a build failure.

**`TrivialRegisterPassable` on a big struct is a silent catastrophe.** It
compiles, and field writes land in the wrong places (cbSize read back as
garbage, a function pointer as 18). Structs passed to the OS by pointer are
`(Defaultable, Copyable, Movable)` — claim register-passability only for
genuinely register-sized values.

**`@fieldwise_init`** gives you the all-fields constructor; you still write
`def __init__(out self)` yourself if you want a zeroing default.

---

## Pointers

- **Non-nullable.** `Pointer(...)` cannot hold null;
  `unsafe_from_address=0` is a comptime error — *"Pointer is non-nullable.
  To construct a null pointer, use Optional[Pointer]"*. At FFI boundaries,
  carry addresses as `Int` and construct the pointer only once it is known
  non-zero. `OptionalPointer` exists for nullable cases.
- `Pointer(to=x)` takes an address; `p[]` dereferences.
- `unsafe_offset(i)` for arithmetic — `p + i` is deprecated.
- `unsafe_bitcast[U]()` re-types; `OpaquePointer[origin]` is
  `Pointer[NoneType, origin]`, the `void *`.
- `MutPointer` / spelling variants exist; grep the stdlib before inventing.

---

## Strings

- **`len(s)` is a compile error on strings** — deliberately ambiguous under
  UTF-8. Use `s.byte_length()`, `len(s.codepoints())`, or
  `len(s.graphemes())`. The error text says exactly this.
- `s.as_c_string_slice()` for a NUL-terminated `char *`;
  `s.unsafe_ptr()` for raw bytes (not NUL-terminated).
- `StaticString` is the comptime string type; struct parameters take it.
  When inference balks, construct explicitly:
  `ComPtr[StaticString("IStream")]`.
- t-strings exist: `t"Failed to execute {path}"`.
- Windows W-entry points want UTF-16: convert explicitly (see `wide()` in
  `examples/win32/d3dwindow.mojo`).

---

## Collections

- **`list[0].field = x` mutates a copy**, not the element. Build the value
  fully, then `list.append(value^)`; or operate through `unsafe_ptr()`.
- Construction: `List[T](length=n, fill=v)`; `resize(n, fill)` needs the
  fill argument.
- `list.unsafe_ptr()` is the stable heap address — with the list's true
  origin, which converts fine into variadic calls and needs an AnyOrigin
  cast into declared signatures.
- **Tuples do not iterate**: `for x in (a, b, c)` fails with *"'Tuple[...]'
  does not implement the '__iter__' method"*. Use a `List` or unroll.
- **Mutable aliasing is enforced**: several mutable pointers into the same
  object in one call is *"aliasing values passed mutably"*. Separate
  out-parameters get separate locals.

---

## Reserved words that bite

`fn`, `struct`, `interface` cannot be identifiers or parameter names —
`struct: StaticString` in a parameter list is *"expected parameter name"*.
Use `type_name`, `iface`, `proc`.

---

## Platform gating

The stdlib's pattern, and ours:

```mojo
comptime if CompilationTarget.is_windows():
    ...
elif CompilationTarget.is_linux():
    ...
else:
    CompilationTarget.unsupported_target_error[operation="thing"]()
```

`comptime assert CompilationTarget.is_linux() or ...` guards whole
functions; adding `is_windows()` to those gates is how os.Process came to
compile here. The runtime never sees the untaken branches.

---

## This fork's own surface

Queries answered by the compiler during elaboration, from the Win32 metadata
database (std.sys._winkb): `winkb_struct_size`, `winkb_struct_align`,
`winkb_field_offset`, `winkb_vtable_index`, `winkb_interface_iid`,
`winkb_function_dll`, `winkb_db_hash`, `winkb_db_schema_version`. All fold
to constants; a name the metadata does not know is a compile error naming
the source line.

COM (std.sys._com): `com_method` / `com_method_of` dispatch through
metadata-derived vtable slots (four instructions, same as C++);
`ComPtr[interface_name]` owns a reference with copy=AddRef,
deinit=Release, move=free, `adopt=` for pre-counted out-params, and
`query_interface[Target]` with the IID inferred from the type.

Modules (std.sys._win32): `Win32Module("name.dll")` through the
process-lifetime cache; `.function[Sig]("Export")` raises on a missing
export instead of returning a junk callable.
