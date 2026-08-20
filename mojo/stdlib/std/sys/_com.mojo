# ===----------------------------------------------------------------------=== #
# Calling COM.
#
# A COM object is a pointer to a pointer to an array of function pointers. A
# call is therefore an indexed load from that array, which means the only fact
# a caller needs beyond the method's signature is which slot -- and slots are
# in the Win32 metadata, so `winkb_vtable_index` supplies them and nothing here
# has to be generated or kept in step with Windows by hand.
#
# That matters most for inherited methods. `IStream::Write` is inherited from
# `ISequentialStream`, which itself sits above `IUnknown`, so Write is slot 4
# rather than slot 0 -- exactly the arithmetic a hand-written binding gets
# wrong, silently, by calling whatever else happens to be in that slot.
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer, OpaquePointer
from std.sys._winkb import winkb_vtable_index


@always_inline
def com_method[
    Sig: TrivialRegisterPassable, slot: Int
](this: OpaquePointer[MutUntrackedOrigin]) -> Sig:
    """Fetch the function in vtable `slot` of a COM object.

    `Sig` must be a thin C-ABI function type whose first parameter is the
    interface pointer, since COM passes `this` as an ordinary first argument.

    Parameters:
        Sig: The method's function type, e.g.
            `def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> UInt32`.
        slot: The vtable slot, normally from `winkb_vtable_index`.

    Args:
        this: The interface pointer.

    Returns:
        The method, ready to call with `this` as its first argument.
    """
    # *this is the vtable; the vtable is an array of function pointers.
    var vtable = this.unsafe_bitcast[OpaquePointer[MutUntrackedOrigin]]()[]
    var entry = vtable.unsafe_bitcast[
        OpaquePointer[MutUntrackedOrigin]
    ]().unsafe_offset(slot)[]
    return Pointer(to=entry).unsafe_bitcast[Sig]()[]


@always_inline
def com_method_of[
    Sig: TrivialRegisterPassable,
    interface_name: StaticString,
    method_name: StaticString,
](this: OpaquePointer[MutUntrackedOrigin]) -> Sig:
    """Fetch a COM method by name, taking its slot from the Win32 metadata.

    Name the interface that *declares* the method rather than the one being
    called through: metadata slots are absolute, so asking for
    `["ISequentialStream", "Write"]` yields 4, which is correct for any
    `IStream` too.

    Parameters:
        Sig: The method's thin C-ABI function type.
        interface_name: The interface declaring the method.
        method_name: The method's name.

    Args:
        this: The interface pointer.

    Returns:
        The method, ready to call with `this` as its first argument.
    """
    return com_method[Sig, winkb_vtable_index[interface_name, method_name]()](
        this
    )


# ===----------------------------------------------------------------------=== #
# A note on origins, which is where this is easy to get wrong
#
# Interface pointers use OpaquePointer[MutUntrackedOrigin], and that is the
# documented use of an untracked origin: memory from outside the Mojo program,
# aliasing no value the compiler manages.
#
# Everything ELSE a COM method touches -- out-parameters, descriptor structs,
# buffers -- IS Mojo-owned memory, and casting its pointer to an untracked
# origin tells the lifetime checker the pointer does not alias it. The
# compiler is then free to hand the callee a temporary: the call succeeds, the
# write lands nowhere, and the local keeps its old value. It can also appear
# to work, which is worse. This was found by sentinel: a counter set to 999
# survived a Write that reported success.
#
# So a Sig's pointer parameters are spelled over AnyOrigin, which keeps the
# aliasing ("might access any memory value"):
#
#     def (
#         OpaquePointer[MutUntrackedOrigin],      # this -- from Windows
#         Pointer[UInt32, MutAnyOrigin],          # out-param -- ours
#     ) thin abi("C") -> c_int
#
# and a call site casts to the SAME:
#
#     write(this, ..., Pointer(to=written).unsafe_origin_cast[MutAnyOrigin]())
#
# Variadic calls (external_call, _DLCallable) need no cast at all: pass
# Pointer(to=local) and the true origin is inferred, which is what the
# standard library itself does at every libc boundary.
# ===----------------------------------------------------------------------=== #
