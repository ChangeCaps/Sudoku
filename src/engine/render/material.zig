const std = @import("std");
const vk = @import("vulkan");

const Entity = @import("../Entity.zig");
const Game = @import("../Game.zig");
const Transform = @import("../Transform.zig");

const Camera = @import("Camera.zig");
const DrawCommand = @import("DrawCommand.zig");
const Hdr = @import("Hdr.zig");
const Mesh = @import("Mesh.zig");
const RenderPlugin = @import("RenderPlugin.zig");
const PreparedMeshes = @import("PreparedMeshes.zig");
const PreparedTransform = @import("PreparedTransform.zig");
const PreparedLight = @import("PreparedLight.zig");
const Query = @import("../query.zig").Query;

const asset = @import("../asset.zig");
const system = @import("../system.zig");

pub const VertexAttribute = struct {
    name: []const u8,
    format: vk.VertexFormat,
};

pub const MaterialPipeline = struct {
    input_assembly: vk.GraphicsPipeline.InputAssembly = .{},
    rasterization: vk.GraphicsPipeline.Rasterization = .{},
    depth_stencil: ?vk.GraphicsPipeline.DepthStencil = .{
        .depth_test = true,
        .depth_write = true,
    },
    color_attachment: vk.GraphicsPipeline.ColorBlendAttachment = .{},
};

pub const MaterialPhase = enum {
    Prepare,
    Queue,
};

pub fn MaterialPlugin(comptime T: type) type {
    return struct {
        const Self = @This();

        const Pipeline = struct {
            layout: vk.BindGroupLayout,
            pipeline: vk.GraphicsPipeline,
            material: MaterialPipeline,
            attributes: []const VertexAttribute,

            fn init(
                device: vk.Device,
                hdr: Hdr,
                transform_pipeline: PreparedTransform.Pipeline,
                camera_pipeline: Camera.Pipeline,
                prepared_light: PreparedLight,
                allocator: std.mem.Allocator,
            ) !Pipeline {
                const entries = T.bindGroupLayoutEntries();

                // create the layout first
                const layout = try device.createBindGroupLayout(.{
                    .entries = entries,
                });
                errdefer layout.deinit();

                const attributes = vertexAttributes(T);

                const vertex_bindings = try allocator.alloc(
                    vk.GraphicsPipeline.VertexBinding,
                    attributes.len,
                );
                defer allocator.free(vertex_bindings);

                const vertex_attributes = try allocator.alloc(
                    vk.GraphicsPipeline.VertexAttribute,
                    attributes.len,
                );
                defer allocator.free(vertex_attributes);

                for (attributes, 0..) |attribute, i| {
                    vertex_attributes[i] = .{
                        .location = @intCast(i),
                        .format = attribute.format,
                        .offset = 0,
                    };

                    vertex_bindings[i] = .{
                        .binding = @intCast(i),
                        .stride = attribute.format.size(),
                        .input_rate = .Vertex,
                        .attributes = vertex_attributes[i .. i + 1],
                    };
                }

                const material_pipeline = materialPipeline(T);

                // create the pipeline
                const pipeline = try device.createGraphicsPipeline(.{
                    .vertex = .{
                        .shader = vertexShader(T),
                        .entry_point = "main",
                        .bindings = vertex_bindings,
                    },
                    .fragment = .{
                        .shader = fragmentShader(T),
                        .entry_point = "main",
                    },
                    .input_assembly = material_pipeline.input_assembly,
                    .rasterization = material_pipeline.rasterization,
                    .depth_stencil = material_pipeline.depth_stencil,
                    .color_blend = .{
                        .attachments = &.{
                            material_pipeline.color_attachment,
                        },
                    },
                    .layouts = &.{
                        layout,
                        transform_pipeline.layout,
                        camera_pipeline.layout,
                        prepared_light.bind_group_layout,
                    },
                    .render_pass = hdr.render_pass,
                    .subpass = 0,
                });
                errdefer pipeline.deinit();

                return .{
                    .layout = layout,
                    .pipeline = pipeline,
                    .material = material_pipeline,
                    .attributes = attributes,
                };
            }

            pub fn deinit(self: Pipeline) void {
                self.layout.deinit();
                self.pipeline.deinit();
            }
        };

        const Prepared = struct {
            state: T.State,
            pool: vk.BindGroupPool,
            group: vk.BindGroup,

            pub fn deinit(self: *Prepared) void {
                T.deinitState(&self.state);
                self.pool.deinit();
            }
        };

        const PreparedAssets = struct {
            assets: std.AutoHashMap(asset.AssetId(T), Prepared),

            pub fn init(allocator: std.mem.Allocator) PreparedAssets {
                return PreparedAssets{
                    .assets = std.AutoHashMap(asset.AssetId(T), Prepared).init(allocator),
                };
            }

            pub fn deinit(self: *PreparedAssets) void {
                var it = self.assets.valueIterator();
                while (it.next()) |prepared| {
                    prepared.deinit();
                }

                self.assets.deinit();
            }
        };

        fn prepare(
            device: *vk.Device,
            staging_buffer: *vk.StagingBuffer,
            pipeline: *Pipeline,
            materials: *asset.Assets(T),
            prepared: *PreparedAssets,
        ) !void {
            // we need to initialize the prepared assets with the materials
            var it = materials.iterator();
            while (it.next()) |entry| {
                // if the material is already prepared, skip it
                if (prepared.assets.contains(entry.id)) continue;

                std.log.debug("Preparing material: {}\n", .{T});

                const entries = T.bindGroupLayoutEntries();

                // we need to create a pool for each unique type of binding
                var pool_sizes: [16]vk.BindGroupPool.PoolSize = undefined;
                var count: u8 = 0;

                // iterate over the layout entries and create a pool size for each unique type
                entries: for (entries) |layout_entry| {
                    // if the type is already in the pool sizes, increment the count
                    for (pool_sizes[0..count]) |*pool_size| {
                        if (pool_size.type == layout_entry.type) {
                            pool_size.count += 1;
                            continue :entries;
                        }
                    }

                    pool_sizes[count] = .{
                        .type = layout_entry.type,
                        .count = 1,
                    };

                    count += 1;
                }

                // create the pool
                const pool = try device.createBindGroupPool(.{
                    .pool_sizes = pool_sizes[0..count],
                    .max_groups = 1,
                });
                errdefer pool.deinit();

                // allocate the group from the pool
                const group = try pool.alloc(pipeline.layout);

                // create the state
                var state = try T.initState(device.*, group);
                errdefer T.deinitState(&state);

                // add the prepared material to the prepared assets
                try prepared.assets.put(entry.id, .{
                    .state = state,
                    .pool = pool,
                    .group = group,
                });
            }

            // now we need to update all the prepared materials
            it = materials.iterator();
            while (it.next()) |entry| {
                const prepared_asset = prepared.assets.getPtr(entry.id).?;

                // update the state
                try entry.asset.item.update(
                    &prepared_asset.state,
                    staging_buffer,
                );
            }
        }

        // this system will queue up all the entities for rendering
        fn queue(
            draw_commands: *DrawCommand.Queue,
            pipeline: *Pipeline,
            prepared_assets: *PreparedAssets,
            prepared_meshes: *PreparedMeshes,
            prepared_light: *PreparedLight,
            cameras: Query(struct {
                prepared_camera: *Camera.Prepared,
            }),
            query: Query(struct {
                entity: Entity,
                material: *asset.AssetId(T),
                mesh: *asset.AssetId(Mesh),
                transform: *Transform,
                prepared_transform: *PreparedTransform,
            }),
        ) !void {
            var cameras_it = cameras.iterator();
            const camera = cameras_it.next() orelse return;

            var it = query.iterator();
            while (it.next()) |q| {
                const material = prepared_assets.assets.get(q.material.*) orelse {
                    continue;
                };

                const mesh = prepared_meshes.get(q.mesh.*) orelse {
                    continue;
                };

                std.log.debug("Queueing entity: {}\n", .{q.entity});

                const vertex_buffers = try draw_commands.allocator.alloc(
                    vk.Buffer,
                    pipeline.attributes.len,
                );
                errdefer draw_commands.allocator.free(vertex_buffers);

                for (pipeline.attributes, 0..) |attribute, i| {
                    const buffer = mesh.getAttribute(attribute.name).?;
                    vertex_buffers[i] = buffer;
                }

                const bind_groups = try draw_commands.allocator.alloc(vk.BindGroup, 4);
                bind_groups[0] = material.group;
                bind_groups[1] = q.prepared_transform.bind_group;
                bind_groups[2] = camera.prepared_camera.bind_group;
                bind_groups[3] = prepared_light.bind_group;

                const draw = DrawCommand{
                    .entity = q.entity,
                    .transmissive = false,
                    .pipeline = pipeline.pipeline,
                    .bind_groups = bind_groups,
                    .vertex_buffers = vertex_buffers,
                    .index_buffer = mesh.index_buffer,
                    .index_count = mesh.index_count,
                };

                try draw_commands.push(draw);
            }
        }

        pub fn buildPlugin(self: Self, game: *Game) !void {
            _ = self;
            // make sure the render plugin is added
            game.requirePlugin(RenderPlugin);

            // add the prepare system
            const s = try game.addSystem(prepare);
            try s.label(MaterialPhase.Prepare);
            try s.after(Game.Phase.Update);
            try s.before(Game.Phase.Render);

            // add the queue system
            const q = try game.addSystem(queue);
            try q.label(MaterialPhase.Queue);
            try q.after(MaterialPhase.Prepare);
            try q.before(Game.Phase.Render);

            const materials = asset.Assets(T).init(game.allocator());
            try game.world.addResource(materials);

            const prepared = PreparedAssets.init(game.allocator());
            try game.world.addResource(prepared);

            const device = game.world.resource(vk.Device);
            const hdr = game.world.resource(Hdr);
            const transform_pipeline = game.world.resource(PreparedTransform.Pipeline);
            const camera_pipeline = game.world.resource(Camera.Pipeline);
            const prepared_light = game.world.resource(PreparedLight);

            const pipeline = try Pipeline.init(
                device,
                hdr,
                transform_pipeline,
                camera_pipeline,
                prepared_light,
                game.allocator(),
            );
            errdefer pipeline.deinit();

            try game.world.addResource(pipeline);
        }
    };
}

fn vertexAttributes(comptime T: type) []const VertexAttribute {
    if (@hasDecl(T, "vertexAttributes")) {
        return T.vertexAttributes();
    } else {
        return &.{
            .{ .name = Mesh.POSITION, .format = .f32x3 },
            .{ .name = Mesh.NORMAL, .format = .f32x3 },
            .{ .name = Mesh.TEX_COORD_0, .format = .f32x2 },
        };
    }
}

fn vertexShader(comptime T: type) vk.Spirv {
    if (@hasDecl(T, "vertexShader")) {
        return T.vertexShader();
    } else {
        return .{};
    }
}

fn fragmentShader(comptime T: type) vk.Spirv {
    if (@hasDecl(T, "fragmentShader")) {
        return T.fragmentShader();
    } else {
        return .{};
    }
}

fn materialPipeline(comptime T: type) MaterialPipeline {
    if (@hasDecl(T, "materialPipeline")) {
        return T.materialPipeline();
    } else {
        return MaterialPipeline{};
    }
}
