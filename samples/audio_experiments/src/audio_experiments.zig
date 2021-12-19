const std = @import("std");
const win32 = @import("win32");
const w = win32.base;
const d2d1 = win32.d2d1;
const d3d12 = win32.d3d12;
const dwrite = win32.dwrite;
const dml = win32.directml;
const xaudio2 = win32.xaudio2;
const xaudio2fx = win32.xaudio2fx;
const wasapi = win32.wasapi;
const mf = win32.mf;
const common = @import("common");
const gfx = common.graphics;
const sfx = common.audio;
const lib = common.library;
const c = common.c;
const pix = common.pix;
const vm = common.vectormath;
const tracy = common.tracy;
const math = std.math;
const assert = std.debug.assert;
const hrPanic = lib.hrPanic;
const hrPanicOnFail = lib.hrPanicOnFail;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub export var D3D12SDKVersion: u32 = 4;
pub export var D3D12SDKPath: [*:0]const u8 = ".\\d3d12\\";

const window_name = "zig-gamedev: audio experiments";
const window_width = 1920;
const window_height = 1080;

const DemoState = struct {
    gctx: gfx.GraphicsContext,
    actx: sfx.AudioContext,
    gui: gfx.GuiContext,
    frame_stats: lib.FrameStats,

    music: *sfx.Stream,

    brush: *d2d1.ISolidColorBrush,
    info_tfmt: *dwrite.ITextFormat,
};

fn init(gpa_allocator: std.mem.Allocator) DemoState {
    const tracy_zone = tracy.zone(@src(), 1);
    defer tracy_zone.end();

    const actx = sfx.AudioContext.init();

    hrPanicOnFail(mf.MFStartup(mf.VERSION, 0));

    const samples = sfx.loadSamples(gpa_allocator, L("content/drum_bass_hard.flac"));
    defer samples.deinit();

    var music = sfx.Stream.create(gpa_allocator, actx.device, L("content/Broke For Free - Night Owl.mp3"));
    hrPanicOnFail(music.voice.Start(0, xaudio2.COMMIT_NOW));

    {
        var reverb_apo: ?*w.IUnknown = null;
        hrPanicOnFail(xaudio2fx.createReverb(&reverb_apo, 0));
        defer _ = reverb_apo.?.Release();

        var effect_descriptor = [_]xaudio2.EFFECT_DESCRIPTOR{.{
            .pEffect = reverb_apo.?,
            .InitialState = w.FALSE,
            .OutputChannels = 2,
        }};
        const effect_chain = xaudio2.EFFECT_CHAIN{ .EffectCount = 1, .pEffectDescriptors = &effect_descriptor };
        hrPanicOnFail(music.voice.SetEffectChain(&effect_chain));

        hrPanicOnFail(music.voice.SetEffectParameters(
            0,
            &xaudio2fx.REVERB_PARAMETERS.initDefault(),
            @sizeOf(xaudio2fx.REVERB_PARAMETERS),
            xaudio2.COMMIT_NOW,
        ));
    }

    const window = lib.initWindow(gpa_allocator, window_name, window_width, window_height) catch unreachable;

    var arena_allocator_state = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena_allocator_state.deinit();
    const arena_allocator = arena_allocator_state.allocator();

    _ = pix.loadGpuCapturerLibrary();
    _ = pix.setTargetWindow(window);
    _ = pix.beginCapture(
        pix.CAPTURE_GPU,
        &pix.CaptureParameters{ .gpu_capture_params = .{ .FileName = L("capture.wpix") } },
    );

    var gctx = gfx.GraphicsContext.init(window);
    gctx.present_flags = 0;
    gctx.present_interval = 1;

    const brush = blk: {
        var brush: *d2d1.ISolidColorBrush = undefined;
        hrPanicOnFail(gctx.d2d.context.CreateSolidColorBrush(
            &.{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 0.5 },
            null,
            @ptrCast(*?*d2d1.ISolidColorBrush, &brush),
        ));
        break :blk brush;
    };

    const info_tfmt = blk: {
        var info_txtfmt: *dwrite.ITextFormat = undefined;
        hrPanicOnFail(gctx.dwrite_factory.CreateTextFormat(
            L("Verdana"),
            null,
            dwrite.FONT_WEIGHT.BOLD,
            dwrite.FONT_STYLE.NORMAL,
            dwrite.FONT_STRETCH.NORMAL,
            32.0,
            L("en-us"),
            @ptrCast(*?*dwrite.ITextFormat, &info_txtfmt),
        ));
        break :blk info_txtfmt;
    };
    hrPanicOnFail(info_tfmt.SetTextAlignment(.LEADING));
    hrPanicOnFail(info_tfmt.SetParagraphAlignment(.NEAR));

    //
    // Begin frame to init/upload resources to the GPU.
    //
    gctx.beginFrame();
    gctx.endFrame();
    gctx.beginFrame();

    pix.beginEventOnCommandList(@ptrCast(*d3d12.IGraphicsCommandList, gctx.cmdlist), "GPU init");

    var gui = gfx.GuiContext.init(arena_allocator, &gctx, 1);

    _ = pix.endEventOnCommandList(@ptrCast(*d3d12.IGraphicsCommandList, gctx.cmdlist));

    gctx.endFrame();
    gctx.finishGpuCommands();

    _ = pix.endCapture();

    return .{
        .gctx = gctx,
        .gui = gui,
        .actx = actx,
        .music = music,
        .frame_stats = lib.FrameStats.init(),
        .brush = brush,
        .info_tfmt = info_tfmt,
    };
}

fn deinit(demo: *DemoState, gpa_allocator: std.mem.Allocator) void {
    demo.gctx.finishGpuCommands();
    _ = demo.brush.Release();
    _ = demo.info_tfmt.Release();
    demo.gui.deinit(&demo.gctx);
    demo.gctx.deinit();
    demo.music.destroy();
    hrPanicOnFail(mf.MFShutdown());
    demo.actx.deinit();
    lib.deinitWindow(gpa_allocator);
    demo.* = undefined;
}

fn update(demo: *DemoState) void {
    demo.frame_stats.update();
    const dt = demo.frame_stats.delta_time;
    lib.newImGuiFrame(dt);

    //var state: xaudio2.VOICE_STATE = std.mem.zeroes(xaudio2.VOICE_STATE);
    //demo.music.voice.GetState(&state, 0);
    //std.log.info("{}", .{state});
}

fn draw(demo: *DemoState) void {
    var gctx = &demo.gctx;
    gctx.beginFrame();

    const back_buffer = gctx.getBackBuffer();
    gctx.addTransitionBarrier(back_buffer.resource_handle, d3d12.RESOURCE_STATE_RENDER_TARGET);
    gctx.flushResourceBarriers();

    gctx.cmdlist.OMSetRenderTargets(
        1,
        &[_]d3d12.CPU_DESCRIPTOR_HANDLE{back_buffer.descriptor_handle},
        w.TRUE,
        null,
    );
    gctx.cmdlist.ClearRenderTargetView(
        back_buffer.descriptor_handle,
        &[4]f32{ 0.0, 0.0, 0.0, 1.0 },
        0,
        null,
    );

    demo.gui.draw(gctx);

    gctx.beginDraw2d();
    {
        const stats = &demo.frame_stats;
        var buffer = [_]u8{0} ** 64;
        const text = std.fmt.bufPrint(
            buffer[0..],
            "FPS: {d:.1}\nCPU time: {d:.3} ms",
            .{ stats.fps, stats.average_cpu_time },
        ) catch unreachable;

        demo.brush.SetColor(&.{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 });
        lib.drawText(
            gctx.d2d.context,
            text,
            demo.info_tfmt,
            &d2d1.RECT_F{
                .left = 10.0,
                .top = 10.0,
                .right = @intToFloat(f32, gctx.viewport_width),
                .bottom = @intToFloat(f32, gctx.viewport_height),
            },
            @ptrCast(*d2d1.IBrush, demo.brush),
        );
    }
    gctx.endDraw2d();

    gctx.endFrame();
}

pub fn main() !void {
    lib.init();
    defer lib.deinit();

    var gpa_allocator_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_allocator_state.deinit();
        std.debug.assert(leaked == false);
    }
    const gpa_allocator = gpa_allocator_state.allocator();

    var demo = init(gpa_allocator);
    defer deinit(&demo, gpa_allocator);

    while (true) {
        var message = std.mem.zeroes(w.user32.MSG);
        const has_message = w.user32.peekMessageA(&message, null, 0, 0, w.user32.PM_REMOVE) catch false;
        if (has_message) {
            _ = w.user32.translateMessage(&message);
            _ = w.user32.dispatchMessageA(&message);
            if (message.message == w.user32.WM_QUIT) {
                break;
            }
        } else {
            update(&demo);
            draw(&demo);
        }
    }
}
