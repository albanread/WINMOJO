# ===----------------------------------------------------------------------=== #
# Win32 metadata, queried while compiling.
#
# The Win32 API is described precisely -- struct sizes, field offsets, vtable
# order, interface IIDs -- in a metadata database, and the compiler can read it
# during elaboration. So a binding states a name and the compiler supplies the
# rest, instead of a generator restating 15,000 struct layouts that then have to
# be kept in step with Windows by hand.
#
# Every function here resolves to a constant before any code is generated. A
# name the metadata does not know is a compile error, not a wrong answer.
# ===----------------------------------------------------------------------=== #

from std.collections.string.string_span import _get_kgen_string


def winkb_struct_size[name: StaticString]() -> Int:
    """The size in bytes of a Win32 struct, from the metadata.

    Parameters:
        name: The unqualified Win32 struct name, e.g. "POINT".

    Returns:
        The size in bytes.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<winkb_query, `,
            _get_kgen_string["struct_size"](),
            `, `,
            _get_kgen_string[name](),
            `> : index`,
        ]
    )


def winkb_struct_align[name: StaticString]() -> Int:
    """The alignment in bytes of a Win32 struct, from the metadata.

    Parameters:
        name: The unqualified Win32 struct name.

    Returns:
        The alignment in bytes.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<winkb_query, `,
            _get_kgen_string["struct_align"](),
            `, `,
            _get_kgen_string[name](),
            `> : index`,
        ]
    )


def winkb_field_offset[type_name: StaticString, field: StaticString]() -> Int:
    """The byte offset of a field within a Win32 struct.

    This is what makes a declaration checkable rather than merely plausible:
    a Mojo struct can assert that its own layout agrees with what Windows
    expects, and fail to build if it does not.

    Parameters:
        type_name: The unqualified Win32 struct name.
        field: The field name within it.

    Returns:
        The offset in bytes from the start of the struct.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<winkb_query, `,
            _get_kgen_string["field_offset"](),
            `, `,
            _get_kgen_string[type_name](),
            `, `,
            _get_kgen_string[field](),
            `> : index`,
        ]
    )


def winkb_vtable_index[type_name: StaticString, method: StaticString]() -> Int:
    """The vtable slot of a COM method.

    A COM call is an indexed load from the interface's vtable, so this is the
    only fact a caller needs that cannot be written down from the signature.
    Taking it from the metadata means the 46,000-odd methods across Windows
    need no generated constants at all.

    Parameters:
        type_name: The COM interface name, e.g. "IFileDialog".
        method: The method name on it.

    Returns:
        The zero-based vtable slot.
    """
    return Int(
        mlir_value=__mlir_attr[
            `#kgen.param.expr<winkb_query, `,
            _get_kgen_string["vtable_index"](),
            `, `,
            _get_kgen_string[type_name](),
            `, `,
            _get_kgen_string[method](),
            `> : index`,
        ]
    )


def winkb_function_dll[name: StaticString]() -> StaticString:
    """Which DLL exports a Win32 function.

    Parameters:
        name: The exported function name, e.g. "GetCursorPos".

    Returns:
        The DLL name, e.g. "USER32.dll".
    """
    var res = __mlir_attr[
        `#kgen.param.expr<winkb_query, `,
        _get_kgen_string["function_dll"](),
        `, `,
        _get_kgen_string[name](),
        `> : !kgen.string`,
    ]
    return StaticString(res)
