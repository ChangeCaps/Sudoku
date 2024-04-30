const std = @import("std");

const Entity = @import("Entity.zig");
const World = @import("World.zig");

const Commands = @This();

pub fn AddComponent(comptime T: type) type {
    return struct {
        const Self = @This();

        entity: Entity,
        component: T,

        fn apply(self: *Self, world: *World) !void {
            if (world.getEntity(self.entity)) |entity| {
                try entity.addComponent(self.component);
            } else {
                std.log.warn("Entity not found, {}", .{self.entity});
            }
        }
    };
}

pub const SystemParamState = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayListUnmanaged(Command),
};

world: *World,
state: *SystemParamState,

pub fn add(self: *const Commands, command: anytype) !void {
    const cmd = try Command.init(command, self.state.allocator);
    try self.state.queue.append(self.state.allocator, cmd);
}

pub fn addComponent(self: *const Commands, entity: Entity, component: anytype) !void {
    const T = @TypeOf(component);
    const cmd = AddComponent(T){
        .entity = entity,
        .component = component,
    };

    try self.add(cmd);
}

pub fn systemParamInit(world: *World) !SystemParamState {
    return .{
        .allocator = world.allocator,
        .queue = .{},
    };
}

pub fn systemParamFetch(world: *World, state: *SystemParamState) !Commands {
    return .{
        .world = world,
        .state = state,
    };
}

pub fn systemParamApply(world: *World, state: *SystemParamState) !void {
    for (state.queue.items) |*command| {
        try command.apply(world, state.allocator);
    }

    state.queue.clearRetainingCapacity();
}

pub fn systemParamDeinit(state: *SystemParamState) void {
    state.queue.deinit(state.allocator);
}

const Command = struct {
    data: *u8,
    apply_dyn: *const fn (*u8, *World, std.mem.Allocator) anyerror!void,

    fn init(
        command: anytype,
        allocator: std.mem.Allocator,
    ) !Command {
        const T = @TypeOf(command);

        const Closure = struct {
            fn apply(
                data: *u8,
                world: *World,
                alloc: std.mem.Allocator,
            ) anyerror!void {
                const command_ptr: *T = @ptrCast(@alignCast(data));
                try command_ptr.apply(world);

                if (@hasDecl(T, "deinit")) {
                    command_ptr.deinit();
                }

                if (@sizeOf(T) > 0) {
                    alloc.destroy(command_ptr);
                }
            }
        };

        var data: *T = undefined;

        if (@sizeOf(T) > 0) {
            data = try allocator.create(T);
            data.* = command;
        }

        return .{
            .data = @ptrCast(@alignCast(data)),
            .apply_dyn = Closure.apply,
        };
    }

    fn apply(
        self: *Command,
        world: *World,
        allocator: std.mem.Allocator,
    ) !void {
        try self.apply_dyn(self.data, world, allocator);
    }
};
