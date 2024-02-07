const std = @import("std");
const vk = @import("vulkan");
const Camera = @import("Camera.zig");
const StandardMaterial = @import("StandardMaterial.zig");
const Tonemapper = @import("Tonemapper.zig");
const Mesh = @import("Mesh.zig");
const math = @import("../../math.zig");

const Renderer = @This();

const Hdr = struct {
    color_image: vk.Image,
    color_view: vk.ImageView,
    depth_image: vk.Image,
    depth_view: vk.ImageView,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,

    const COLOR_FORMAT = vk.ImageFormat.R16G16B16A16Sfloat;
    const DEPTH_FORMAT = vk.ImageFormat.D32Sfloat;

    fn init(device: vk.Device, extent: vk.Extent3D) !Hdr {
        const color_image = try createColorImage(device, extent);
        errdefer color_image.deinit();

        const color_view = try color_image.createView(.{
            .format = COLOR_FORMAT,
            .aspect = .{ .color = true },
        });
        errdefer color_view.deinit();

        const depth_image = try createDepthImage(device, extent);
        errdefer depth_image.deinit();

        const depth_view = try depth_image.createView(.{
            .format = DEPTH_FORMAT,
            .aspect = .{ .depth = true },
        });
        errdefer depth_view.deinit();

        const render_pass = try createHdrRenderPass(device);
        errdefer render_pass.deinit();

        const framebuffer = try device.createFramebuffer(.{
            .render_pass = render_pass,
            .attachments = &.{ color_view, depth_view },
            .extent = .{
                .width = extent.width,
                .height = extent.height,
            },
        });

        return .{
            .color_image = color_image,
            .color_view = color_view,
            .depth_image = depth_image,
            .depth_view = depth_view,
            .render_pass = render_pass,
            .framebuffer = framebuffer,
        };
    }

    fn createColorImage(device: vk.Device, extent: vk.Extent3D) !vk.Image {
        return try device.createImage(.{
            .format = COLOR_FORMAT,
            .extent = extent,
            .usage = .{ .color_attachment = true, .sampled = true },
            .memory = .{ .device_local = true },
        });
    }

    fn createDepthImage(device: vk.Device, extent: vk.Extent3D) !vk.Image {
        return try device.createImage(.{
            .format = DEPTH_FORMAT,
            .extent = extent,
            .usage = .{ .depth_stencil_attachment = true },
            .memory = .{ .device_local = true },
        });
    }

    fn recreate(self: *Hdr, device: vk.Device, extent: vk.Extent3D) !void {
        self.color_image.deinit();
        self.color_image = try createColorImage(device, extent);

        self.color_view.deinit();
        self.color_view = try self.color_image.createView(.{
            .format = Hdr.COLOR_FORMAT,
            .aspect = .{ .color = true },
        });

        self.depth_image.deinit();
        self.depth_image = try createDepthImage(device, extent);

        self.depth_view.deinit();
        self.depth_view = try self.depth_image.createView(.{
            .format = Hdr.DEPTH_FORMAT,
            .aspect = .{ .depth = true },
        });

        self.framebuffer.deinit();
        self.framebuffer = try device.createFramebuffer(.{
            .render_pass = self.render_pass,
            .attachments = &.{ self.color_view, self.depth_view },
            .extent = .{
                .width = extent.width,
                .height = extent.height,
            },
        });
    }

    fn deinit(self: Hdr) void {
        self.framebuffer.deinit();
        self.render_pass.deinit();
        self.depth_view.deinit();
        self.depth_image.deinit();
        self.color_view.deinit();
        self.color_image.deinit();
    }
};

const Sdr = struct {
    swapchain: vk.Swapchain,
    render_pass: vk.RenderPass,
    framebuffers: []vk.Framebuffer,

    const COLOR_FORMAT: vk.ImageFormat = vk.ImageFormat.B8G8R8A8Unorm;

    fn init(allocator: std.mem.Allocator, device: vk.Device, surface: vk.Surface) !Sdr {
        const render_pass = try createSdrRenderPass(device);
        const swapchain = try device.createSwapchain(.{
            .surface = surface,
        });

        const framebuffers = try allocator.alloc(vk.Framebuffer, swapchain.images.len);

        for (swapchain.views, 0..) |view, i| {
            framebuffers[i] = try device.createFramebuffer(.{
                .render_pass = render_pass,
                .attachments = &.{view},
                .extent = swapchain.extent.as2D(),
            });
        }

        return .{
            .swapchain = swapchain,
            .render_pass = render_pass,
            .framebuffers = framebuffers,
        };
    }

    fn recreate(self: *Sdr, device: vk.Device, allocator: std.mem.Allocator) !void {
        for (self.framebuffers) |framebuffer| {
            framebuffer.deinit();
        }

        try self.swapchain.recreate();

        self.framebuffers = try allocator.realloc(self.framebuffers, self.swapchain.images.len);

        for (self.swapchain.views, 0..) |view, i| {
            self.framebuffers[i] = try device.createFramebuffer(.{
                .render_pass = self.render_pass,
                .attachments = &.{view},
                .extent = self.swapchain.extent.as2D(),
            });
        }
    }

    fn deinit(self: Sdr, allocator: std.mem.Allocator) void {
        for (self.framebuffers) |framebuffer| {
            framebuffer.deinit();
        }

        allocator.free(self.framebuffers);

        self.render_pass.deinit();
        self.swapchain.deinit();
    }
};

allocator: std.mem.Allocator,
device: vk.Device,
surface: vk.Surface,

sdr: Sdr,
hdr: Hdr,

graphics_pool: vk.CommandPool,
graphics_buffer: vk.CommandBuffer,

time: f32,

camera: Camera,
camera_state: Camera.RenderState,

tonemapper: Tonemapper,

staging_buffer: vk.StagingBuffer,

standard_material_pipeline_state: StandardMaterial.PipelineState,
standard_material_instance_state: StandardMaterial.InstanceState,

in_flight: vk.Fence,
image_available: vk.Semaphore,
render_finished: vk.Semaphore,

pub const Descriptor = struct {
    allocator: std.mem.Allocator,
    device: vk.Device,
    surface: vk.Surface,
};

pub fn init(desc: Descriptor) !Renderer {
    const sdr = try Sdr.init(desc.allocator, desc.device, desc.surface);
    errdefer sdr.deinit(desc.allocator);

    const hdr = try Hdr.init(desc.device, sdr.swapchain.extent);
    errdefer hdr.deinit();

    const graphics_pool = try desc.device.createCommandPool(.Graphics);
    errdefer graphics_pool.deinit();

    const graphics_buffer = try graphics_pool.alloc(.Primary);

    const in_flight = try desc.device.createFence(true);
    errdefer in_flight.deinit();

    const image_available = try desc.device.createSemaphore();
    errdefer image_available.deinit();

    const render_finished = try desc.device.createSemaphore();
    errdefer render_finished.deinit();

    var staging_buffer = try vk.StagingBuffer.init(desc.device, graphics_pool);
    errdefer staging_buffer.deinit();

    const camera_state = try Camera.RenderState.init(desc.device);

    const standard_material_pipeline_state = try StandardMaterial.PipelineState.init(
        desc.device,
        camera_state.bind_group_layout,
        hdr.render_pass,
        0,
    );
    errdefer standard_material_pipeline_state.deinit();

    const mesh = Mesh.cube(1.0, 0xffffffff);

    const standard_material_instance_state = try StandardMaterial.InstanceState.init(
        desc.device,
        standard_material_pipeline_state,
        &staging_buffer,
        mesh,
    );

    const tonemapper = try Tonemapper.init(desc.device, sdr.render_pass, 0);
    try tonemapper.setHdrImage(desc.device, hdr.color_view);

    return .{
        .allocator = desc.allocator,
        .device = desc.device,
        .surface = desc.surface,

        .sdr = sdr,
        .hdr = hdr,

        .graphics_pool = graphics_pool,
        .graphics_buffer = graphics_buffer,

        .time = 0.0,

        .camera = .{},
        .camera_state = camera_state,

        .tonemapper = tonemapper,

        .staging_buffer = staging_buffer,

        .standard_material_pipeline_state = standard_material_pipeline_state,
        .standard_material_instance_state = standard_material_instance_state,

        .in_flight = in_flight,
        .image_available = image_available,
        .render_finished = render_finished,
    };
}

pub fn deinit(self: Renderer) void {
    // very important as it turns out
    self.device.waitIdle() catch {};

    self.render_finished.deinit();
    self.image_available.deinit();
    self.in_flight.deinit();

    self.staging_buffer.deinit();

    self.tonemapper.deinit();

    self.camera_state.deinit();

    self.graphics_pool.deinit();

    self.standard_material_pipeline_state.deinit();
    self.standard_material_instance_state.deinit();

    self.hdr.deinit();
    self.sdr.deinit(self.allocator);
}

fn createHdrRenderPass(device: vk.Device) !vk.RenderPass {
        return vk.RenderPass.init(device, .{
        .attachments = &.{
            .{
                .format = Hdr.COLOR_FORMAT,
                .samples = 1,
                .load_op = .Clear,
                .store_op = .Store,
                .final_layout = .ShaderReadOnlyOptimal,
            },
            .{
                .format = Hdr.DEPTH_FORMAT,
                .samples = 1,
                .load_op = .Clear,
                .store_op = .Store,
                .final_layout = .DepthStencilAttachmentOptimal,
            },
        },
        .subpasses = &.{
            .{
                .color_attachments = &.{
                    .{
                        .attachment = 0,
                        .layout = .ColorAttachmentOptimal,
                    },
                },
                .depth_stencil_attachment = .{
                    .attachment = 1,
                    .layout = .DepthStencilAttachmentOptimal,
                },
            },
        },
        .dependencies = &.{
            .{
                .dst_subpass = 0,
                .src_stage_mask = .{
                    .top_of_pipe = true,
                },
                .dst_stage_mask = .{
                    .color_attachment_output = true,
                    .early_fragment_tests = true,
                },
                .dst_access_mask = .{
                    .depth_stencil_attachment_read = true,
                    .depth_stencil_attachment_write = true,
                    .color_attachment_write = true,
                },
            },
            .{
                .src_subpass = 0,
                .src_stage_mask = .{
                    .color_attachment_output = true,
                },
                .src_access_mask = .{
                    .color_attachment_write = true,
                },
                .dst_stage_mask = .{
                    .fragment_shader = true,
                },
                .dst_access_mask = .{
                    .shader_read = true,
                },
            },
        },
    });
}

fn createSdrRenderPass(device: vk.Device) !vk.RenderPass {
    return vk.RenderPass.init(device, .{
        .attachments = &.{
            .{
                .format = Sdr.COLOR_FORMAT,
                .samples = 1,
                .load_op = .Clear,
                .store_op = .Store,
                .final_layout = .PresentSrc,
            },
        },
        .subpasses = &.{
            .{
                .color_attachments = &.{
                    .{
                        .attachment = 0,
                        .layout = .ColorAttachmentOptimal,
                    },
                },
            },
        },
        .dependencies = &.{
            .{
                .dst_subpass = 0,
                .src_stage_mask = .{
                    .fragment_shader = true,
                },
                .dst_stage_mask = .{
                    .color_attachment_output = true,
                },
                .dst_access_mask = .{
                    .color_attachment_write = true,
                },
            },
        },
    });
}

fn recordCommandBuffer(self: *Renderer, image_index: usize) !void {
    try self.graphics_buffer.reset();
    try self.graphics_buffer.begin(.{});

    self.graphics_buffer.beginRenderPass(.{
        .render_pass = self.hdr.render_pass,
        .framebuffer = self.hdr.framebuffer,
        .render_area = .{
            .extent = self.sdr.swapchain.extent.as2D(),
        },
    });

    self.graphics_buffer.setViewport(.{
        .width = @floatFromInt(self.sdr.swapchain.extent.width),
        .height = @floatFromInt(self.sdr.swapchain.extent.height),
    });

    self.graphics_buffer.setScissor(.{
        .extent = self.sdr.swapchain.extent.as2D(),
    });

    try StandardMaterial.recordInstance(
        self.graphics_buffer,
        self.standard_material_pipeline_state,
        self.standard_material_instance_state,
        self.camera_state.bind_group,
        Mesh.cube(1.0, 0xffffffff),
    );

    self.graphics_buffer.endRenderPass();

    self.graphics_buffer.pipelineBarrier(.{
        .src_stage = .{ .color_attachment_output = true },
        .dst_stage = .{ .color_attachment_output = true },
    });

    self.graphics_buffer.beginRenderPass(.{
        .render_pass = self.sdr.render_pass,
        .framebuffer = self.sdr.framebuffers[image_index],
        .render_area = .{
            .extent = self.sdr.swapchain.extent.as2D(),
        },
    });

    try self.tonemapper.recordCommandBuffer(self.graphics_buffer);

    self.graphics_buffer.endRenderPass();

    try self.graphics_buffer.end();
}

fn recreate(self: *Renderer) !void {
    try self.device.waitIdle();

    try self.sdr.recreate(self.device, self.allocator);
    try self.hdr.recreate(self.device, self.sdr.swapchain.extent);
    try self.tonemapper.setHdrImage(self.device, self.hdr.color_view);
}

pub fn drawFrame(self: *Renderer) !void {
    try self.in_flight.wait(.{});

    const image_index = self.sdr.swapchain.acquireNextImage(.{
        .semaphore = self.image_available,
    }) catch |err| switch (err) {
        error.VK_SUBOPTIMAL_KHR,
        error.VK_ERROR_OUT_OF_DATE_KHR,
        => return try self.recreate(),
        else => return err,
    };

    try self.in_flight.reset();

    try StandardMaterial.prepareInstance(
        self.device,
        &self.standard_material_instance_state,
        &self.staging_buffer,
        math.Mat4.rotate(self.time, math.vec3(1.0, -2.0, 0.8).normalize()),
    );
    self.time += 0.005;

    const width: f32 = @floatFromInt(self.sdr.swapchain.extent.width);
    const height: f32 = @floatFromInt(self.sdr.swapchain.extent.height);

    try self.staging_buffer.write(&self.camera.uniform(width / height));
    try self.staging_buffer.copyBuffer(.{
        .dst = self.camera_state.buffer,
        .size = @sizeOf(Camera.Uniforms),
    });

    try self.recordCommandBuffer(image_index);

    try self.device.graphics.submit(.{
        .wait_semaphores = &.{
            .{
                .semaphore = self.image_available,
                .stage = .{ .color_attachment_output = true },
            },
        },
        .command_buffers = &.{
            self.graphics_buffer,
        },
        .signal_semaphores = &.{
            self.render_finished,
        },
        .fence = self.in_flight,
    });

    self.device.present.present(.{
        .swapchains = &.{
            .{
                .swapchain = self.sdr.swapchain,
                .image_index = image_index,
            },
        },
        .wait_semaphores = &.{
            self.render_finished,
        },
    }) catch |err| switch (err) {
        error.VK_SUBOPTIMAL_KHR,
        error.VK_ERROR_OUT_OF_DATE_KHR,
        => return try self.recreate(),
        else => return err,
    };
}
