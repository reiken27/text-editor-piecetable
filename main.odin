package main

import c "core:c"
import fmt "core:fmt"
import mem "core:mem"
import os2 "core:os/os2"
import slice "core:slice"
import strings "core:strings"
import time "core:time"
import utf8 "core:unicode/utf8"
import ptree "piecetable"
import rl "vendor:raylib"

SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720

Cursor :: struct {
	position:          int,
	cursor_blink_time: f32,
	cursor_visible:    bool,
	cursor_color:      rl.Color,
	desired_col_runes: int,
	has_desired_col:   bool,
	selection_start:   int,
	selection_active:  bool,
	marker_position:   int,
	marker_active:     bool,
}

Editor :: struct {
	table:             ptree.Piece_Table,
	using cursor:      Cursor,
	file_name:         string,
	font:              rl.Font,
	scroll_offset_y:   f32,
	scroll_offset_x:   f32,
	line_height:       f32,
	viewport_width:    f32,
	viewport_height:   f32,
	font_size:         i32,
	status_bar_height: f32,
	line_number_width: f32,
	show_line_numbers: bool,
	using treesitter:  Treesitter_tree,
	should_recenter:   bool, // flag to trigger recentering
}

editor_init :: proc(
	editor: ^Editor,
	custom_font_path: string = "NotoSansJP-Regular.ttf",
	filename: string,
) {
	editor := editor
	editor.font = load_unicode_font(custom_font_path)
	editor.cursor.position = 0
	editor.scroll_offset_y = 0
	editor.scroll_offset_x = 0
	editor.font_size = 20
	editor.line_height = f32(editor.font_size) * 1.2
	editor.cursor_visible = true
	editor.viewport_width = SCREEN_WIDTH
	editor.viewport_height = SCREEN_HEIGHT
	editor.status_bar_height = 40
	editor.desired_col_runes = -1
	editor.has_desired_col = false
	editor.show_line_numbers = true
	editor.line_number_width = 60
	ok := load_file(editor, filename)
	if !ok do return
	editor.file_name = filename
	treesitter_init(editor)
}

editor_cleanup :: proc(editor: ^Editor) {
	ptree.piece_table_destroy(&editor.table)
	if editor.font.texture.id != rl.GetFontDefault().texture.id {
		rl.UnloadFont(editor.font)
	}
}

load_file :: proc(editor: ^Editor, filename: string) -> bool {
	editor := editor
	data, err := os2.read_entire_file_from_path(filename, context.allocator)
	defer delete(data)
	if err != nil {
		fmt.printf("Failed to read file: %s\n", filename)
		return false
	}
	text := string(data)
	editor.table = ptree.piece_table_init(text)
	return true
}

load_unicode_font :: proc(custom_font_path: string = "") -> rl.Font {
	if len(custom_font_path) > 0 {
		cstring_path := strings.clone_to_cstring(custom_font_path)
		defer delete(cstring_path)
		//need to figure out how to load codepoints properly (dynamically?)in order to support unicode
		font := rl.LoadFontEx(cstring_path, 40, nil, 0)

		if font.texture.id != 0 {
			fmt.printf("Loaded custom Unicode font: %s\n", custom_font_path)
			return font
		} else {
			fmt.printf("Warning: Failed to load custom font: %s\n", custom_font_path)
		}
	}
	return rl.GetFontDefault()
}


save_file :: proc(editor: ^Editor) -> bool {

	file, err := os2.open(
		editor.file_name,
		os2.O_WRONLY | os2.O_CREATE | os2.O_TRUNC,
		os2.Permissions_Default,
	)
	if err != nil {
		fmt.println("Failed to open file for writing:", err)
		return false
	}
	defer os2.close(file)

	pt := &editor.table
	total := pt.root.subtree_size

	remaining := total
	pos := 0

	for remaining > 0 {
		node, offset := ptree.find_node_at_position(pt, pos)
		if node == nil {
			break
		}

		available := node.piece.length - offset
		to_write := min(remaining, available)

		buffer: []u8
		switch node.piece.buffer_type {
		case .ORIGINAL:
			buffer = pt.original_buffer[:]
		case .ADD:
			buffer = pt.add_buffer[:]
		}

		piece_start := node.piece.start + offset
		piece_end := piece_start + to_write
		data := buffer[piece_start:piece_end]

		// write this chunk
		written, err := os2.write(file, data)
		if err != nil || written != len(data) {
			fmt.println("Write failed:", err)
			return false
		}

		remaining -= to_write
		pos += to_write
	}

	return true
}


line_col_from_cursor :: proc(editor: ^Editor) -> (line: int, col_runes: int) {
	if editor.cursor.position == 0 {
		return 0, 0
	}
	line_num := ptree.get_line_number_from_offset(&editor.table, editor.cursor.position)
	//TODO add function to do this without string building
	line_str, ok := ptree.get_line(&editor.table, line_num)
	defer delete(line_str)
	if !ok {
		return 0, 0
	}

	start_pos, _, ok2 := ptree.get_line_offset_range(&editor.table, line_num)
	if !ok2 {
		return 0, 0
	}

	// Compute column as rune offset within the line
	byte_offset_in_line := editor.cursor.position - start_pos
	col_runes = 0
	total_bytes := 0

	for r in line_str {
		rune_bytes := utf8.rune_size(r)
		if total_bytes + rune_bytes > byte_offset_in_line {
			break
		}
		total_bytes += rune_bytes
		col_runes += 1
	}

	return line_num, col_runes
}
line_col_from_position :: proc(editor: ^Editor, position: int) -> (line: int, col_runes: int) {
	if position <= 0 {
		return 0, 0
	}
	line_num := ptree.get_line_number_from_offset(&editor.table, position)
	//TODO add function to do this without string building
	line_str, ok := ptree.get_line(&editor.table, line_num)
	defer delete(line_str)
	if !ok {
		return 0, 0
	}
	start_pos, _, ok2 := ptree.get_line_offset_range(&editor.table, line_num)
	if !ok2 {
		return 0, 0
	}
	// Compute column as rune offset within the line
	byte_offset_in_line := position - start_pos // Changed from editor.cursor.position
	col_runes = 0
	total_bytes := 0
	for r in line_str {
		rune_bytes := utf8.rune_size(r)
		if total_bytes + rune_bytes > byte_offset_in_line {
			break
		}
		total_bytes += rune_bytes
		col_runes += 1
	}
	return line_num, col_runes
}

draw_debug_cursor :: proc(editor: ^Editor, position: int, color: rl.Color) {
	// Convert position -> line / column
	line, col_runes := line_col_from_position(editor, position)

	cursor_y := f32(line) * editor.line_height
	cursor_x: f32 = 0.0

	if line < editor.table.root.subtree_lines {
		line_text, ok := ptree.get_line(&editor.table, line)
		defer delete(line_text)

		if ok && col_runes > 0 {
			if col_runes <= strings.rune_count(line_text) {
				rune_idx := 0
				for _, byte_idx in line_text {
					if rune_idx == col_runes {
						prefix := line_text[:byte_idx]
						cprefix := strings.clone_to_cstring(prefix, context.temp_allocator)
						size := rl.MeasureTextEx(editor.font, cprefix, f32(editor.font_size), 0)
						cursor_x = size.x
						break
					}
					rune_idx += 1
				}

				if rune_idx == strings.rune_count(line_text) {
					cline := strings.clone_to_cstring(line_text, context.temp_allocator)
					size := rl.MeasureTextEx(editor.font, cline, f32(editor.font_size), 0)
					cursor_x = size.x
				}
			}
		}
	}

	// Account for scrolling + line numbers
	text_offset_x: f32 = 0
	if editor.show_line_numbers {
		text_offset_x = editor.line_number_width
	}

	screen_x := text_offset_x + cursor_x - editor.scroll_offset_x
	screen_y := cursor_y - editor.scroll_offset_y

	// Draw cursor rectangle
	rl.DrawRectangle(i32(screen_x), i32(screen_y), 2, editor.font_size, color)
}


recenter_camera_on_cursor :: proc(editor: ^Editor) {
	cursor_line, cursor_col_runes := line_col_from_cursor(editor)
	cursor_y: f32 = f32(cursor_line) * editor.line_height
	cursor_x: f32 = 0.0

	if cursor_line < editor.table.root.subtree_lines {
		line_text, ok := ptree.get_line(&editor.table, cursor_line)
		defer delete(line_text)

		if ok && cursor_col_runes > 0 {
			if cursor_col_runes <= strings.rune_count(line_text) {
				rune_idx := 0
				for r, byte_idx in line_text {
					if rune_idx == cursor_col_runes {
						line_prefix := line_text[:byte_idx]
						cstring_prefix := strings.clone_to_cstring(
							line_prefix,
							context.temp_allocator,
						)
						text_size := rl.MeasureTextEx(
							editor.font,
							cstring_prefix,
							f32(editor.font_size),
							0,
						)
						cursor_x = text_size.x
						break
					}
					rune_idx += 1
				}
				if rune_idx == strings.rune_count(line_text) {
					cstring_line := strings.clone_to_cstring(line_text, context.temp_allocator)
					text_size := rl.MeasureTextEx(
						editor.font,
						cstring_line,
						f32(editor.font_size),
						0,
					)
					cursor_x = text_size.x
				}
			}
		}
	}

	// Vertical scrolling - center the cursor line on screen
	editor.scroll_offset_y = cursor_y - (editor.viewport_height / 2.0)

	// Clamp to prevent scrolling past the document bounds
	if editor.scroll_offset_y < 0 {
		editor.scroll_offset_y = 0
	}

	max_scroll :=
		f32(editor.table.root.subtree_lines) * editor.line_height - editor.viewport_height
	if max_scroll > 0 && editor.scroll_offset_y > max_scroll {
		editor.scroll_offset_y = max_scroll
	}

	// Horizontal scrolling - center the cursor horizontally
	available_width := editor.viewport_width
	if editor.show_line_numbers {
		available_width -= editor.line_number_width
	}

	editor.scroll_offset_x = cursor_x - (available_width / 2.0)

	// Clamp horizontal scroll to prevent negative offset
	if editor.scroll_offset_x < 0 {
		editor.scroll_offset_x = 0
	}
}


render_editor :: proc(editor: ^Editor) {
	editor.viewport_width = f32(rl.GetScreenWidth())
	editor.viewport_height = f32(rl.GetScreenHeight())
	cursor_line, cursor_col_runes := line_col_from_cursor(editor)

	// Only recenter if flag is set
	if editor.should_recenter {
		recenter_camera_on_cursor(editor)
		editor.should_recenter = false
	}

	// Calculate cursor position for rendering (but don't update scroll)
	cursor_y: f32 = f32(cursor_line) * editor.line_height
	cursor_x: f32 = 0.0

	if cursor_line < editor.table.root.subtree_lines {
		line_text, ok := ptree.get_line(&editor.table, cursor_line)
		defer delete(line_text)

		if ok && cursor_col_runes > 0 {
			if cursor_col_runes <= strings.rune_count(line_text) {
				rune_idx := 0
				for r, byte_idx in line_text {
					if rune_idx == cursor_col_runes {
						line_prefix := line_text[:byte_idx]
						cstring_prefix := strings.clone_to_cstring(
							line_prefix,
							context.temp_allocator,
						)
						text_size := rl.MeasureTextEx(
							editor.font,
							cstring_prefix,
							f32(editor.font_size),
							0,
						)
						cursor_x = text_size.x
						break
					}
					rune_idx += 1
				}
				if rune_idx == strings.rune_count(line_text) {
					cstring_line := strings.clone_to_cstring(line_text, context.temp_allocator)
					text_size := rl.MeasureTextEx(
						editor.font,
						cstring_line,
						f32(editor.font_size),
						0,
					)
					cursor_x = text_size.x
				}
			}
		}
	}

	render_text(editor)

	// Draw cursor (even if offscreen)
	if editor.cursor_visible {
		text_offset_x: f32 = 0
		if editor.show_line_numbers {
			text_offset_x = editor.line_number_width
		}

		cursor_screen_x := text_offset_x + cursor_x - editor.scroll_offset_x
		cursor_screen_y := cursor_y - editor.scroll_offset_y

		rl.DrawRectangle(i32(cursor_screen_x), i32(cursor_screen_y), 2, editor.font_size, rl.GREEN)
	}

	if editor.selection_active {
		draw_debug_cursor(editor, editor.selection_start, rl.RED)
	}

	if editor.marker_active {
		draw_debug_cursor(editor, editor.marker_position, rl.ORANGE)
	}

	// Status bar
	status_y := editor.viewport_height
	rl.DrawRectangle(
		0,
		i32(status_y - editor.status_bar_height),
		i32(editor.viewport_width),
		40,
		{40, 40, 40, 255},
	)

	line_nums_status := editor.show_line_numbers ? "ON" : "OFF"
	status_text := fmt.aprintf(
		"Position: %d | Line: %d, Col: %d | Line Numbers: %s | Ctrl+S: Save, Ctrl+L: Toggle Line Numbers | selection: %d %t",
		editor.cursor.position,
		cursor_line + 1,
		cursor_col_runes + 1,
		line_nums_status,
		editor.selection_start,
		editor.selection_active,
	)
	defer delete(status_text)
	cstring_status := strings.clone_to_cstring(status_text, context.temp_allocator)
	rl.DrawTextEx(
		editor.font,
		cstring_status,
		{10, status_y - editor.status_bar_height},
		cast(f32)editor.font_size,
		0,
		rl.GRAY,
	)
}

render_text :: proc(editor: ^Editor) {
	line_height := editor.line_height
	first_visible := int(editor.scroll_offset_y / line_height)
	if first_visible < 1 do first_visible = 0

	last_visible := int((editor.scroll_offset_y + editor.viewport_height) / line_height) + 1
	if last_visible > editor.table.root.subtree_lines {
		last_visible = editor.table.root.subtree_lines
	}
	text_offset_x: f32 = 0

	if editor.show_line_numbers {
		text_offset_x = editor.line_number_width

		// draw line number background
		rl.DrawRectangle(
			0,
			0,
			i32(editor.line_number_width),
			i32(editor.viewport_height),
			{30, 30, 30, 255},
		)

		// separator line
		rl.DrawLine(
			i32(editor.line_number_width - 1),
			0,
			i32(editor.line_number_width - 1),
			i32(editor.viewport_height),
			{50, 50, 50, 255},
		)
	}

	for line_idx in first_visible ..< last_visible {
		y := f32(line_idx) * line_height - editor.scroll_offset_y

		line_text, _ := ptree.get_line(&editor.table, line_idx)

		defer delete(line_text)

		// Remove trailing newline before rendering
		line_without_newline := strings.trim_right(line_text, "\n")
		cstring_line := strings.clone_to_cstring(line_without_newline)
		defer delete(cstring_line)

		rl.DrawTextEx(
			editor.font,
			cstring_line,
			rl.Vector2{text_offset_x - editor.scroll_offset_x, y},
			f32(editor.font_size),
			0,
			rl.WHITE,
		)
		// line numbers
		if editor.show_line_numbers {
			line_num_text := fmt.aprintf("%d", line_idx + 1)
			defer delete(line_num_text)
			cstring_line_num := strings.clone_to_cstring(line_num_text, context.temp_allocator)
			text_width :=
				rl.MeasureTextEx(editor.font, cstring_line_num, f32(editor.font_size), 0).x
			line_num_x := editor.line_number_width - text_width - 5
			rl.DrawTextEx(
				editor.font,
				cstring_line_num,
				rl.Vector2{line_num_x, y},
				f32(editor.font_size),
				0,
				{120, 120, 120, 255},
			)
		}

	}

}


main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				for _, entry in track.allocation_map {
					fmt.eprintf("%v leaked %v bytes\n", entry.location, entry.size)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	args := os2.args
	if len(args) < 2 {
		fmt.println("Usage: raylib-editor <filename>")
		return
	}


	filename := args[1]
	rl.SetConfigFlags(rl.ConfigFlags{.WINDOW_RESIZABLE})
	rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, rl.TextFormat("HM-EDITOR: %s", filename))
	defer rl.CloseWindow()
	rl.SetTargetFPS(100000)
	editor: Editor
	editor_init(&editor, "./NotoSansJP-Regular.ttf", filename)
	defer editor_cleanup(&editor)


	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		handle_input(&editor)
		rl.ClearBackground(rl.Color{25, 25, 25, 255})
		render_editor(&editor)
		rl.DrawText(
			rl.TextFormat("%d", rl.GetFPS()),
			cast(i32)editor.viewport_width - 80,
			0,
			20,
			rl.RED,
		)
		rl.EndDrawing()
	}

}
