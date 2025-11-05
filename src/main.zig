const std = @import("std");
const win = std.os.windows;
const vk = @import("vk.zig");

var g_hChildStd_IN_Rd: win.HANDLE = undefined;
var g_hChildStd_IN_Wr: win.HANDLE = undefined;
var g_hChildStd_OUT_Rd: win.HANDLE = undefined;
var g_hChildStd_OUT_Wr: win.HANDLE = undefined;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const hInstance: win.HINSTANCE = @ptrCast(GetModuleHandleW(null));
    const window_hwnd = try wWinMain(allocator, hInstance, null, null, 3);

    const vk_renderer = try vk.init(allocator, hInstance, window_hwnd);
    defer vk_renderer.destroy();

    var msg: MSG = undefined;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);

        try vk_renderer.drawFrame();
    }
}

const WNDPROC = *const fn (
    hwnd: win.HWND,
    uMsg: win.UINT,
    wParam: win.WPARAM,
    lParam: win.LPARAM,
) callconv(.winapi) win.LRESULT;

const WS_OVERLAPPED = 0x00000000;
const WS_CAPTION = WS_BORDER | WS_DLGFRAME;
const WS_BORDER = 0x00800000;
const WS_DLGFRAME = 0x00400000;
const WS_SYSMENU = 0x00080000;
const WS_THICKFRAME = 0x00040000;
const WS_MINIMIZEBOX = 0x00020000;
const WS_MAXIMIZEBOX = 0x00010000;
const WS_OVERLAPPEDWINDOW = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

const WM_DESTROY = 0x0002;
const WM_PAINT = 0x000F;

const CW_USEDEFAULT = @as(i32, @bitCast(@as(u32, 0x80000000)));

const COLOR_WINDOW = 5;

const WNDCLASSEXW = extern struct {
    cbSize: win.UINT = @sizeOf(WNDCLASSEXW),
    style: win.UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?win.HINSTANCE,
    hIcon: ?win.HICON,
    hCursor: ?win.HCURSOR,
    hbrBackground: ?win.HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?win.HICON,
};

pub const MSG = extern struct {
    hWnd: ?win.HWND,
    message: win.UINT,
    wParam: win.WPARAM,
    lParam: win.LPARAM,
    time: win.DWORD,
    pt: win.POINT,
    lPrivate: win.DWORD,
};

const PAINTSTRUCT = extern struct {
    hdc: win.HDC,
    fErase: win.BOOL,
    rcPaint: win.RECT,
    fRestore: win.BOOL,
    fIncUpdate: win.BOOL,
    rgbReserved: [32]win.BYTE,
};

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) win.HINSTANCE;

extern "user32" fn RegisterClassExW(window_class: *const WNDCLASSEXW) callconv(.winapi) win.ATOM;

extern "user32" fn CreateWindowExW(
    dwExStyle: win.DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: win.DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWindParent: ?win.HWND,
    hMenu: ?win.HMENU,
    hInstance: ?win.HINSTANCE,
    lpParam: ?win.LPVOID,
) callconv(.winapi) win.HWND;

extern "user32" fn ShowWindow(hWnd: win.HWND, nCmdShow: i32) callconv(.winapi) win.BOOL;

pub extern "user32" fn GetMessageW(
    lpMsg: *MSG,
    hWnd: ?win.HWND,
    wMsgFilterMin: win.UINT,
    wMsgFilterMax: win.UINT,
) callconv(.winapi) win.BOOL;

pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) win.BOOL;

pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) win.LRESULT;

extern "user32" fn DefWindowProcW(
    hWnd: win.HWND,
    Msg: win.UINT,
    wParam: win.WPARAM,
    lParam: win.LPARAM,
) callconv(.winapi) win.LRESULT;

extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;

extern "user32" fn BeginPaint(hWnd: win.HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) win.HDC;

extern "user32" fn EndPaint(hWnd: win.HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) win.BOOL;

extern "user32" fn FillRect(hDC: win.HDC, lprc: *const win.RECT, hbr: win.HBRUSH) callconv(.winapi) i32;

fn WindowProc(
    hwnd: win.HWND,
    uMsg: win.UINT,
    wParam: win.WPARAM,
    lParam: win.LPARAM,
) callconv(.winapi) win.LRESULT {
    switch (uMsg) {
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            const hdc: win.HDC = BeginPaint(hwnd, &ps);

            // All painting occurs here, between BeginPaint and EndPaint.
            _ = FillRect(hdc, &ps.rcPaint, @ptrFromInt(COLOR_WINDOW + 1));

            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        else => return DefWindowProcW(hwnd, uMsg, wParam, lParam),
    }
}

pub fn wWinMain(
    allocator: std.mem.Allocator,
    hInstance: ?win.HINSTANCE,
    hPrevInstance: ?win.HINSTANCE,
    pCmdLine: ?win.PWSTR,
    nCmdShow: c_int,
) !win.HWND {
    _ = hPrevInstance;
    _ = pCmdLine;

    const class_name_raw: []win.WCHAR = try std.unicode.utf8ToUtf16LeAlloc(allocator, "pity window class");
    defer allocator.free(class_name_raw);
    const CLASS_NAME = try allocator.allocSentinel(u16, class_name_raw.len, 0);
    std.mem.copyForwards(u16, CLASS_NAME[0..class_name_raw.len], class_name_raw);
    var wc: WNDCLASSEXW = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = CLASS_NAME;
    _ = RegisterClassExW(&wc);

    const window_name_raw: []win.WCHAR = try std.unicode.utf8ToUtf16LeAlloc(allocator, "pity");
    defer allocator.free(window_name_raw);
    const WINDOW_NAME = try allocator.allocSentinel(u16, window_name_raw.len, 0);
    std.mem.copyForwards(u16, WINDOW_NAME[0..window_name_raw.len], window_name_raw);
    const hwnd: win.HWND = CreateWindowExW(
        0, // Optional window styles.
        CLASS_NAME, // Window class
        WINDOW_NAME, // Window text
        WS_OVERLAPPEDWINDOW, // Window style

        // Size and position
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        null, // Parent window
        null, // Menu
        hInstance, // Instance handle
        null, // Additional application data
    );

    _ = ShowWindow(hwnd, nCmdShow);

    return hwnd;
}
