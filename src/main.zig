const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const WINDOW_WIDTH = 900;
const WINDOW_HEIGHT = 900;
const BOARD_SIZE = 30;
const TICK_TIME = 1000;
const BLOCK_SIZE = 30.0;

const Field = struct {
    alive: bool,
    neighbors: u8,
};

pub fn main() !void {
    if (!c.SDL_SetAppMetadata("Cellular automata", "1.0", "cellular-automata")) {
        return error.SDLInitializationFailed;
    }

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    if (!c.SDL_CreateWindowAndRenderer("Cellular automata", WINDOW_WIDTH, WINDOW_HEIGHT, 0, &window, &renderer)) {
        c.SDL_Log("Unable to create window and renderer %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_DestroyWindow(window);
    defer c.SDL_DestroyRenderer(renderer);

    var board = [_]Field{Field{
        .alive = false,
        .neighbors = 0,
    }} ** (BOARD_SIZE * BOARD_SIZE);
    var render_board: [BOARD_SIZE * BOARD_SIZE]c.SDL_FRect = undefined;
    var render_count: usize = 0;

    var quit = false;
    var paused = true;
    var current_time: u64 = 0;
    var last_time: u64 = 0;
    var accumulator: u64 = 0;
    var game_speed_modifier: f32 = 1;

    var compute_thread_handle: std.Thread = undefined;
    compute_thread_handle = std.Thread.spawn(.{}, compute_neighbors, .{&board}) catch {
        return;
    };
    while (!quit) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => {
                    quit = true;
                },
                c.SDL_EVENT_KEY_DOWN => {
                    const key_code = event.key.key;
                    switch (key_code) {
                        c.SDLK_ESCAPE => quit = true,
                        c.SDLK_SPACE => paused = !paused,
                        c.SDLK_EQUALS => game_speed_modifier = @min(game_speed_modifier * 1.3, 10),
                        c.SDLK_MINUS => game_speed_modifier = @max(game_speed_modifier * 0.7, 0.5),
                        else => {},
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    var x: f32 = undefined;
                    var y: f32 = undefined;

                    _ = c.SDL_GetMouseState(&x, &y);

                    const board_x: usize = @as(usize, @intFromFloat(x)) / 30;
                    const board_y: usize = @as(usize, @intFromFloat(y)) / 30;

                    board[board_x * BOARD_SIZE + board_y].alive = !board[board_x * BOARD_SIZE + board_y].alive;

                    paused = true;
                },
                else => {},
            }
        }

        current_time = c.SDL_GetTicks();
        if (!paused) {
            accumulator += @as(u64, @intFromFloat(@as(f32, @floatFromInt(current_time - last_time)) * game_speed_modifier));
        } else {
            // Copy from board to render_board
            render_count = 0;
            for (board, 0..) |field, i| {
                if (field.alive) {
                    const x = i / BOARD_SIZE;
                    const y = @mod(i, BOARD_SIZE);

                    render_board[render_count] = c.SDL_FRect{
                        .x = @as(f32, @floatFromInt(x)) * BLOCK_SIZE,
                        .y = @as(f32, @floatFromInt(y)) * BLOCK_SIZE,
                        .w = BLOCK_SIZE,
                        .h = BLOCK_SIZE,
                    };
                    render_count += 1;
                }
            }
            compute_thread_handle = std.Thread.spawn(.{}, compute_neighbors, .{&board}) catch {
                return;
            };
        }
        if (accumulator >= TICK_TIME) {
            defer accumulator -= TICK_TIME;

            compute_thread_handle.join();

            // Tick is happenning
            for (&board) |*field| {
                if (field.alive and field.neighbors < 2 or field.neighbors > 3) {
                    field.alive = false;
                }
                if (!field.alive and field.neighbors == 3) {
                    field.alive = true;
                }
            }

            // Copy from board to render_board
            render_count = 0;
            for (board, 0..) |field, i| {
                if (field.alive) {
                    const x = i / BOARD_SIZE;
                    const y = @mod(i, BOARD_SIZE);

                    render_board[render_count] = c.SDL_FRect{
                        .x = @as(f32, @floatFromInt(x)) * BLOCK_SIZE,
                        .y = @as(f32, @floatFromInt(y)) * BLOCK_SIZE,
                        .w = BLOCK_SIZE,
                        .h = BLOCK_SIZE,
                    };
                    render_count += 1;
                }
            }

            compute_thread_handle = std.Thread.spawn(.{}, compute_neighbors, .{&board}) catch {
                return;
            };
        }
        last_time = current_time;

        handle_sdl_error(c.SDL_SetRenderDrawColor(renderer, 100, 149, 237, 255));
        handle_sdl_error(c.SDL_RenderClear(renderer));

        // Render the board
        handle_sdl_error(c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255));
        handle_sdl_error(c.SDL_RenderFillRects(renderer, &render_board, @intCast(render_count)));

        for (0..BOARD_SIZE * BOARD_SIZE) |i| {
            handle_sdl_error(c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255));
            const x = i / BOARD_SIZE;
            const y = @mod(i, BOARD_SIZE);

            const x_pos = @as(f32, @floatFromInt(x)) * BLOCK_SIZE;
            const y_pos = @as(f32, @floatFromInt(y)) * BLOCK_SIZE;

            handle_sdl_error(c.SDL_RenderRect(renderer, &.{
                .x = x_pos,
                .y = y_pos,
                .w = BLOCK_SIZE,
                .h = BLOCK_SIZE,
            }));
            var buf: [12]u8 = undefined;
            const text = try std.fmt.bufPrintZ(&buf, "{d}", .{board[i].neighbors});
            handle_sdl_error(c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255));
            handle_sdl_error(c.SDL_RenderDebugText(renderer, x_pos + BLOCK_SIZE / 2, y_pos + BLOCK_SIZE / 2, text.ptr));
        }

        handle_sdl_error(c.SDL_RenderPresent(renderer));
        c.SDL_Delay(17);
    }
}

fn handle_sdl_error(no_errors: bool) void {
    if (!no_errors) {
        std.log.warn("Error occured: {s}", .{c.SDL_GetError()});
    }
}

const NEIGHBORS = [8]isize{
    -BOARD_SIZE - 1,
    -BOARD_SIZE,
    -BOARD_SIZE + 1,
    -1,
    1,
    BOARD_SIZE - 1,
    BOARD_SIZE,
    BOARD_SIZE + 1,
};

fn compute_neighbors(board: *[BOARD_SIZE * BOARD_SIZE]Field) void {
    for (board, 0..) |*field, i| {
        var neighbors: u8 = 0;

        const i_isize: isize = @as(isize, @intCast(i));

        for (NEIGHBORS) |neighbor| {
            if (i_isize + neighbor < 0 or i_isize + neighbor >= board.len) {
                continue;
            }
            if (@mod(i_isize, BOARD_SIZE) == 0 and @mod(neighbor, BOARD_SIZE) == BOARD_SIZE - 1) {
                continue;
            }
            if (@mod(i_isize, BOARD_SIZE) == BOARD_SIZE - 1 and @mod(neighbor, BOARD_SIZE) == 1) {
                continue;
            }

            if (board[@as(usize, @intCast(i_isize + neighbor))].alive) {
                neighbors += 1;
            }
        }

        field.neighbors = neighbors;
    }
}
