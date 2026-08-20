# An animated Julia set, rendered by a pixel shader on the Adreno, from Mojo
# on Windows ARM64. HLSL is compiled at run time with D3DCompile, the
# fullscreen triangle comes from SV_VertexID (no vertex buffer, no input
# layout), and the animation parameter travels in a 16-byte constant buffer.
#
# Everything the pipeline needs to know about Windows -- struct sizes, every
# vtable slot, which DLL exports D3DCompile -- is queried from the metadata
# by the compiler. There is not one hardcoded slot number or GUID below.
#
# The new objects (blobs, shaders, the constant buffer) are ComPtr-owned, so
# their refcounting is the type system's problem: adopt on creation, Release
# on scope exit, moves free.

from std.ffi import c_int, OwnedDLHandle
from std.math import cos, sin
from std.memory import Pointer, OpaquePointer
from std.sys.info import size_of
from std.sys._winkb import winkb_struct_size, winkb_function_dll
from std.sys._com import ComPtr, _guid_bytes, com_method_of
from std.sys._winkb import winkb_interface_iid
from std.sys._win32 import Win32Module


@fieldwise_init
struct WNDCLASSEXW(Defaultable, Copyable, Movable):
    var cbSize: UInt32
    var style: UInt32
    var lpfnWndProc: Int
    var cbClsExtra: Int32
    var cbWndExtra: Int32
    var hInstance: Int
    var hIcon: Int
    var hCursor: Int
    var hbrBackground: Int
    var lpszMenuName: Int
    var lpszClassName: Int
    var hIconSm: Int

    def __init__(out self):
        self.cbSize = 0
        self.style = 0
        self.lpfnWndProc = 0
        self.cbClsExtra = 0
        self.cbWndExtra = 0
        self.hInstance = 0
        self.hIcon = 0
        self.hCursor = 0
        self.hbrBackground = 0
        self.lpszMenuName = 0
        self.lpszClassName = 0
        self.hIconSm = 0


@fieldwise_init
struct DXGI_SWAP_CHAIN_DESC(Defaultable, Copyable, Movable):
    var Width: UInt32
    var Height: UInt32
    var RefreshRateNumerator: UInt32
    var RefreshRateDenominator: UInt32
    var Format: UInt32
    var ScanlineOrdering: UInt32
    var Scaling: UInt32
    var SampleCount: UInt32
    var SampleQuality: UInt32
    var BufferUsage: UInt32
    var BufferCount: UInt32
    var OutputWindow: Int
    var Windowed: Int32
    var SwapEffect: UInt32
    var Flags: UInt32

    def __init__(out self):
        self.Width = 0
        self.Height = 0
        self.RefreshRateNumerator = 0
        self.RefreshRateDenominator = 0
        self.Format = 0
        self.ScanlineOrdering = 0
        self.Scaling = 0
        self.SampleCount = 0
        self.SampleQuality = 0
        self.BufferUsage = 0
        self.BufferCount = 0
        self.OutputWindow = 0
        self.Windowed = 0
        self.SwapEffect = 0
        self.Flags = 0


@fieldwise_init
struct D3D11_BUFFER_DESC(Defaultable, Copyable, Movable):
    var ByteWidth: UInt32
    var Usage: UInt32
    var BindFlags: UInt32
    var CPUAccessFlags: UInt32
    var MiscFlags: UInt32
    var StructureByteStride: UInt32

    def __init__(out self):
        self.ByteWidth = 0
        self.Usage = 0
        self.BindFlags = 0
        self.CPUAccessFlags = 0
        self.MiscFlags = 0
        self.StructureByteStride = 0


@fieldwise_init
struct D3D11_VIEWPORT(Defaultable, Copyable, Movable):
    var TopLeftX: Float32
    var TopLeftY: Float32
    var Width: Float32
    var Height: Float32
    var MinDepth: Float32
    var MaxDepth: Float32

    def __init__(out self):
        self.TopLeftX = 0.0
        self.TopLeftY = 0.0
        self.Width = 0.0
        self.Height = 0.0
        self.MinDepth = 0.0
        self.MaxDepth = 0.0


@fieldwise_init
struct MSG(Defaultable, Copyable, Movable):
    var hwnd: Int
    var message: UInt32
    var _pad: UInt32
    var wParam: Int
    var lParam: Int
    var time: UInt32
    var pt_x: Int32
    var pt_y: Int32

    def __init__(out self):
        self.hwnd = 0
        self.message = 0
        self._pad = 0
        self.wParam = 0
        self.lParam = 0
        self.time = 0
        self.pt_x = 0
        self.pt_y = 0


def wide(s: StaticString) -> List[UInt16]:
    var out = List[UInt16]()
    for byte in s.as_bytes():
        out.append(UInt16(Int(byte)))
    out.append(0)
    return out^


def cstr(s: StaticString) -> List[UInt8]:
    """A NUL-terminated byte buffer for narrow C string parameters."""
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    out.append(0)
    return out^


comptime HLSL: StaticString = """
struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

VSOut vsmain(uint id : SV_VertexID) {
    VSOut o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    o.uv = uv;
    return o;
}

cbuffer Params : register(b0) { float4 p; };  // x,y: c   z: aspect   w: time

float4 psmain(VSOut i) : SV_Target {
    float2 z = float2((i.uv.x * 2.0 - 1.0) * p.z, i.uv.y * 2.0 - 1.0) * 1.5;
    float2 c = float2(p.x, p.y);
    float m = 0.0;
    bool escaped = false;
    [loop] for (int k = 0; k < 160; k++) {
        z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        float r2 = dot(z, z);
        if (r2 > 16.0) {
            m = (float)k - log2(log2(r2)) + 4.0;
            escaped = true;
            break;
        }
    }
    if (!escaped)
        return float4(0.02, 0.01, 0.05, 1.0);
    float3 col =
        0.5 + 0.5 * cos(6.28318 * (m * 0.015 + float3(0.00, 0.33, 0.67)));
    return float4(col, 1.0);
}
"""


def blob_ptr(blob: ComPtr) raises -> Int:
    return com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> Int,
        "ID3DBlob",
        "GetBufferPointer",
    ](blob.interface())(blob.interface())


def blob_size(blob: ComPtr) raises -> Int:
    return com_method_of[
        def (OpaquePointer[MutUntrackedOrigin]) thin abi("C") -> Int,
        "ID3DBlob",
        "GetBufferSize",
    ](blob.interface())(blob.interface())


def blob_text(blob: ComPtr) raises -> String:
    """The bytes of an ID3DBlob as a String -- shader compile errors."""
    var ptr = blob_ptr(blob)
    var n = blob_size(blob)

    var bytes = List[UInt8]()
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=ptr)
    for i in range(n):
        bytes.append(src.unsafe_offset(i)[])
    return String(unsafe_from_utf8=Span(bytes))


def compile_shader(
    compile_fn: def (
        Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
        Pointer[Int, MutAnyOrigin],
        Pointer[Int, MutAnyOrigin],
    ) thin abi("C") -> Int32,
    source: StaticString,
    entry: StaticString,
    target: StaticString,
) raises -> ComPtr[StaticString("ID3DBlob")]:
    """Compiles one HLSL entry point, raising with the compiler's own text."""
    var src = cstr(source)
    var entry_c = cstr(entry)
    var target_c = cstr(target)
    var code_addr: Int = 0
    var errors_addr: Int = 0

    var hr = compile_fn(
        Int(src.unsafe_ptr()),
        len(src) - 1,  # exclude the NUL
        Int(0),  # source name
        Int(0),  # defines
        Int(0),  # includes
        Int(entry_c.unsafe_ptr()),
        Int(target_c.unsafe_ptr()),
        UInt32(0),
        UInt32(0),
        Pointer(to=code_addr).unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=errors_addr).unsafe_origin_cast[MutAnyOrigin](),
    )

    if hr != 0:
        var message = String("(no error blob)")
        if errors_addr != 0:
            var errors = ComPtr[StaticString("ID3DBlob")](adopt=errors_addr)
            message = blob_text(errors)
        raise Error("HLSL " + String(entry) + " failed: " + message)

    return ComPtr[StaticString("ID3DBlob")](adopt=code_addr)


def main() raises:
    comptime assert (
        size_of[D3D11_BUFFER_DESC]() == winkb_struct_size["D3D11_BUFFER_DESC"]()
    ), "D3D11_BUFFER_DESC does not match Windows"
    comptime assert (
        size_of[D3D11_VIEWPORT]() == winkb_struct_size["D3D11_VIEWPORT"]()
    ), "D3D11_VIEWPORT does not match Windows"
    comptime assert (
        size_of[DXGI_SWAP_CHAIN_DESC]()
        == winkb_struct_size["DXGI_SWAP_CHAIN_DESC"]()
    ), "DXGI_SWAP_CHAIN_DESC does not match Windows"

    var user32 = OwnedDLHandle("user32.dll")
    var kernel32 = OwnedDLHandle("kernel32.dll")
    var d3d11 = OwnedDLHandle("d3d11.dll")

    var GetModuleHandleW = kernel32.get_function[Int]("GetModuleHandleW")
    var GetLastError = kernel32.get_function[UInt32]("GetLastError")
    var RegisterClassExW = user32.get_function[UInt16]("RegisterClassExW")
    var CreateWindowExW = user32.get_function[Int]("CreateWindowExW")
    var ShowWindow = user32.get_function[c_int]("ShowWindow")
    var PeekMessageW = user32.get_function[c_int]("PeekMessageW")
    var DispatchMessageW = user32.get_function[Int]("DispatchMessageW")
    var DestroyWindow = user32.get_function[c_int]("DestroyWindow")
    var create_device = d3d11.get_function[c_int](
        "D3D11CreateDeviceAndSwapChain"
    )

    # The shader compiler ships with Windows; the metadata says where.
    print("D3DCompile lives in", winkb_function_dll["D3DCompile"]())
    var compiler_dll = Win32Module("d3dcompiler_47.dll")
    var D3DCompile = compiler_dll.function[
        def (
            Int, Int, Int, Int, Int, Int, Int, UInt32, UInt32,
            Pointer[Int, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> Int32
    ]("D3DCompile")

    var def_proc = user32.get_symbol[NoneType]("DefWindowProcW")
    if not def_proc:
        raise Error("DefWindowProcW not found")

    # -- window ------------------------------------------------------------
    var hInstance = GetModuleHandleW(Int(0))
    var class_name = wide("MojoJuliaWindow")
    var title = wide("Julia set - Mojo pixel shader on Windows ARM64")

    var wc = WNDCLASSEXW()
    wc.cbSize = UInt32(size_of[WNDCLASSEXW]())
    wc.style = 0x0003
    wc.lpfnWndProc = Int(def_proc.value())
    wc.hInstance = hInstance
    wc.lpszClassName = Int(class_name.unsafe_ptr())

    if RegisterClassExW(Pointer(to=wc)) == 0:
        raise Error(
            "RegisterClassExW failed, GetLastError = " + String(GetLastError())
        )

    comptime WIDTH = 960
    comptime HEIGHT = 720
    var hwnd = CreateWindowExW(
        UInt32(0),
        class_name.unsafe_ptr(),
        title.unsafe_ptr(),
        UInt32(0x00CF0000),
        c_int(100),
        c_int(100),
        c_int(WIDTH),
        c_int(HEIGHT),
        Int(0),
        Int(0),
        hInstance,
        Int(0),
    )
    if hwnd == 0:
        raise Error("CreateWindowExW failed")
    _ = ShowWindow(hwnd, c_int(5))

    # -- device + swap chain -----------------------------------------------
    var desc = DXGI_SWAP_CHAIN_DESC()
    desc.Width = UInt32(WIDTH)
    desc.Height = UInt32(HEIGHT)
    desc.RefreshRateNumerator = 60
    desc.RefreshRateDenominator = 1
    desc.Format = 87  # DXGI_FORMAT_B8G8R8A8_UNORM
    desc.SampleCount = 1
    desc.BufferUsage = 32  # DXGI_USAGE_RENDER_TARGET_OUTPUT
    desc.BufferCount = 2
    desc.OutputWindow = hwnd
    desc.Windowed = 1
    desc.SwapEffect = 4  # DXGI_SWAP_EFFECT_FLIP_DISCARD

    var swapchain_addr: Int = 0
    var device_addr: Int = 0
    var level: Int = 0
    var context_addr: Int = 0
    var hr = create_device(
        Int(0),
        UInt32(1),
        Int(0),
        UInt32(0),
        Int(0),
        UInt32(0),
        UInt32(7),
        Pointer(to=desc),
        Pointer(to=swapchain_addr),
        Pointer(to=device_addr),
        Pointer(to=level),
        Pointer(to=context_addr),
    )
    if hr != 0 or swapchain_addr == 0:
        raise Error("Direct3D device creation failed")

    var swapchain = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=swapchain_addr
    )
    var device = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=device_addr
    )
    var context = OpaquePointer[MutUntrackedOrigin](
        unsafe_from_address=context_addr
    )

    # -- back buffer + render target view ----------------------------------
    var backbuf_addr: Int = 0
    # The IID comes from the metadata; _guid_bytes reorders it for COM.
    var iid_texture = _guid_bytes(winkb_interface_iid["ID3D11Texture2D"]())

    var hr2 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[UInt8, MutAnyOrigin],
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "IDXGISwapChain",
        "GetBuffer",
    ](swapchain)(
        swapchain,
        UInt32(0),
        iid_texture.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
        Pointer(to=backbuf_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr2 != 0:
        raise Error("GetBuffer failed")
    var backbuffer = ComPtr[StaticString("ID3D11Texture2D")](
        adopt=backbuf_addr
    )

    var rtv_addr: Int = 0
    var hr3 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateRenderTargetView",
    ](device)(
        device,
        backbuf_addr,
        Int(0),
        Pointer(to=rtv_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr3 != 0:
        raise Error("CreateRenderTargetView failed")

    # -- shaders -----------------------------------------------------------
    var vs_blob = compile_shader(D3DCompile, HLSL, "vsmain", "vs_5_0")
    var ps_blob = compile_shader(D3DCompile, HLSL, "psmain", "ps_5_0")
    print("shaders compiled")

    var vs_addr: Int = 0
    var hr4 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateVertexShader",
    ](device)(
        device,
        blob_ptr(vs_blob),
        blob_size(vs_blob),
        Int(0),
        Pointer(to=vs_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr4 != 0:
        raise Error("CreateVertexShader failed")
    var vshader = ComPtr[StaticString("ID3D11VertexShader")](adopt=vs_addr)

    var ps_addr: Int = 0
    var hr5 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            Int,
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreatePixelShader",
    ](device)(
        device,
        blob_ptr(ps_blob),
        blob_size(ps_blob),
        Int(0),
        Pointer(to=ps_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr5 != 0:
        raise Error("CreatePixelShader failed")
    var pshader = ComPtr[StaticString("ID3D11PixelShader")](adopt=ps_addr)

    # -- constant buffer ----------------------------------------------------
    var cb_desc = D3D11_BUFFER_DESC()
    cb_desc.ByteWidth = 16  # one float4
    cb_desc.Usage = 0  # D3D11_USAGE_DEFAULT
    cb_desc.BindFlags = 4  # D3D11_BIND_CONSTANT_BUFFER

    var cbuf_addr: Int = 0
    var hr6 = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Pointer[D3D11_BUFFER_DESC, MutAnyOrigin],
            Int,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> c_int,
        "ID3D11Device",
        "CreateBuffer",
    ](device)(
        device,
        Pointer(to=cb_desc).unsafe_origin_cast[MutAnyOrigin](),
        Int(0),
        Pointer(to=cbuf_addr).unsafe_origin_cast[MutAnyOrigin](),
    )
    if hr6 != 0:
        raise Error("CreateBuffer failed")
    var cbuffer = ComPtr[StaticString("ID3D11Buffer")](adopt=cbuf_addr)

    # -- fixed pipeline state, set once -------------------------------------
    var viewport = D3D11_VIEWPORT()
    viewport.Width = Float32(WIDTH)
    viewport.Height = Float32(HEIGHT)
    viewport.MaxDepth = 1.0

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[D3D11_VIEWPORT, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "RSSetViewports",
    ](context)(
        context,
        UInt32(1),
        Pointer(to=viewport).unsafe_origin_cast[MutAnyOrigin](),
    )

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            Pointer[Int, MutAnyOrigin],
            Int,
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "OMSetRenderTargets",
    ](context)(
        context,
        UInt32(1),
        Pointer(to=rtv_addr).unsafe_origin_cast[MutAnyOrigin](),
        Int(0),
    )

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "VSSetShader",
    ](context)(context, vs_addr, Int(0), UInt32(0))

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], Int, Int, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetShader",
    ](context)(context, ps_addr, Int(0), UInt32(0))

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            UInt32,
            UInt32,
            Pointer[Int, MutAnyOrigin],
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "PSSetConstantBuffers",
    ](context)(
        context,
        UInt32(0),
        UInt32(1),
        Pointer(to=cbuf_addr).unsafe_origin_cast[MutAnyOrigin](),
    )

    com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "IASetPrimitiveTopology",
    ](context)(context, UInt32(4))  # TRIANGLELIST

    var update = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin],
            Int,
            UInt32,
            Int,
            Pointer[Float32, MutAnyOrigin],
            UInt32,
            UInt32,
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "UpdateSubresource",
    ](context)
    var draw = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32
        ) thin abi("C") -> NoneType,
        "ID3D11DeviceContext",
        "Draw",
    ](context)
    var present = com_method_of[
        def (
            OpaquePointer[MutUntrackedOrigin], UInt32, UInt32
        ) thin abi("C") -> c_int,
        "IDXGISwapChain",
        "Present",
    ](swapchain)

    # -- the animation -------------------------------------------------------
    var params = List[Float32](length=4, fill=0.0)
    var msg = MSG()
    var frames = 0

    for i in range(900):
        # c orbits just inside the main cardioid's reach, where the sets stay
        # connected and keep changing shape.
        var theta = Float32(i) * 0.012
        params[0] = 0.7885 * cos(theta)
        params[1] = 0.7885 * sin(theta)
        params[2] = Float32(WIDTH) / Float32(HEIGHT)
        params[3] = theta

        update(
            context,
            cbuf_addr,
            UInt32(0),
            Int(0),
            params.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin](),
            UInt32(0),
            UInt32(0),
        )
        draw(context, UInt32(3), UInt32(0))
        var phr = present(swapchain, UInt32(1), UInt32(0))
        if phr != 0:
            raise Error("Present failed, hr = " + String(phr))
        frames += 1

        while PeekMessageW(
            Pointer(to=msg), Int(0), UInt32(0), UInt32(0), UInt32(1)
        ) != 0:
            _ = DispatchMessageW(Pointer(to=msg))

    print("presented", frames, "Julia frames on the GPU")
    _ = DestroyWindow(hwnd)
    print("done")
