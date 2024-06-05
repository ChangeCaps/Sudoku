const std = @import("std");
// const Sudoku = @import("sudoku.zig");
// const Solvers = @import("solvers.zig");

const board = @import("board.zig");
const sudoku = @import("sudoku.zig");
const parse = @import("parse.zig");
const solve = @import("solve.zig");

test "Wow" {
    const T = board.Board(3, 3, .MATRIX, .STACK);
    var b = T.init(null);
    const s = sudoku.Sudoku(3, 3).init(&b);

    s.clear();
}

pub fn main() !void {
    const optionalAllocator: std.mem.Allocator = std.heap.page_allocator;

    const board_stencil = ".................1.....2.3...2...4....3.5......41....6.5.6......7.....2..8.91....";
    var parser = parse.Stencil(3, 3, .BITFIELD).init(optionalAllocator);

    // Allocates b.
    var b = parser.from(board_stencil);
    defer b.deinit();

    b.set_row(0, .{ 3, 0, 6, 5, 0, 8, 4, 0, 0 });
    b.set_row(1, .{ 5, 2, 0, 0, 0, 0, 0, 0, 0 });
    b.set_row(2, .{ 0, 8, 7, 0, 0, 0, 0, 3, 1 });
    b.set_row(3, .{ 0, 0, 3, 0, 1, 0, 0, 8, 0 });
    b.set_row(4, .{ 9, 0, 0, 8, 6, 3, 0, 0, 5 });
    b.set_row(5, .{ 0, 5, 0, 0, 9, 0, 6, 0, 0 });
    b.set_row(6, .{ 1, 3, 0, 0, 0, 0, 2, 5, 0 });
    b.set_row(7, .{ 0, 0, 0, 0, 0, 0, 0, 7, 4 });
    b.set_row(8, .{ 0, 0, 5, 2, 0, 6, 3, 0, 0 });

    const writer = std.io.getStdOut().writer();

    _ = try b.display(writer);

    //b.clear();
    //
    //_ = try b.display(writer);
    //
    //const time: u64 = @intCast(std.time.milliTimestamp());
    //var rng = std.rand.DefaultPrng.init(time);
    //var random = rng.random();
    //
    //b.fill_random_valid(10, &random);
    //
    //_ = try b.display(writer);

    const solveable = solve.solve(.ADVANCED, &b);

    _ = try b.display(writer);

    std.debug.print("Solveable: {}\n", .{solveable});

    std.debug.print("Grid count {d}\n", .{b.k * b.k});

    std.debug.print("As stencil {s}\n", .{try parser.into(b)});

    const errors = try b.validate_all(optionalAllocator);

    std.debug.print("Row errors count: {d}\n", .{errors.get(.ROW).items.len});
    std.debug.print("Column errors count: {d}\n", .{errors.get(.COLUMN).items.len});
    std.debug.print("Grid errors count: {d}\n", .{errors.get(.GRID).items.len});
}
