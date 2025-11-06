package piecetable

import runtime "base:runtime"
import fmt "core:fmt"
import rand "core:math/rand"
import mem "core:mem"
import spall "core:prof/spall"
import slice "core:slice"
import strings "core:strings"
import sync "core:sync"
import time "core:time"

debug_print_piece :: proc(pt: ^Piece_Table, piece: ^Piece, label: string = "") {
	fmt.printf("\n=== %s ===\n", label)
	fmt.printf(
		"Piece: buffer=%v, start=%d, length=%d, line_count=%d\n",
		piece.buffer_type,
		piece.start,
		piece.length,
		piece.linefeed_count,
	)

	// Get the actual text
	text := get_piece_text(pt, piece)
	fmt.printf("Text content: %q\n", string(text))

	// Show line starts for this piece
	line_starts :=
		piece.buffer_type == .ORIGINAL ? pt.line_starts_original[:] : pt.line_starts_add[:]
	fmt.printf("All line_starts: %v\n", line_starts)

	start_idx := binary_search_first_ge(line_starts, piece.start)
	end_idx := binary_search_first_ge(line_starts, piece.start + piece.length)

	fmt.printf("Piece range: [%d, %d)\n", piece.start, piece.start + piece.length)
	fmt.printf("Line start indices: start_idx=%d, end_idx=%d\n", start_idx, end_idx)
	fmt.printf("Line starts in range: %v\n", line_starts[start_idx:end_idx])
	fmt.printf("Calculated line_count: %d\n", end_idx - start_idx)

}

debug_print_tree :: proc(pt: ^Piece_Table, node: ^RB_Node, depth: int = 0) {
	if node == nil do return

	debug_print_tree(pt, node.right, depth + 1)

	for i := 0; i < depth; i += 1 {
		fmt.printf("    ")
	}

	text := get_piece_text(pt, &node.piece)
	fmt.printf(
		"%s[%d] %q (lines:%d, subtree_lines:%d)\n",
		node.color == .RED ? "R" : "B",
		node.piece.length,
		string(text),
		node.piece.linefeed_count,
		node.subtree_lines,
	)

	debug_print_tree(pt, node.left, depth + 1)
}

debug_test_get_all_lines :: proc(pt: ^Piece_Table) {
	fmt.printf("\n=== Testing get_line for all lines ===\n")

	total_lines := pt.root != nil ? pt.root.subtree_lines : 0
	fmt.printf("Total lines in tree: %d\n\n", total_lines)

	for i := 0; i < total_lines + 2; i += 1 { 	// Try a few extra to see failures
		line, ok := get_line(pt, i)
		if ok {
			fmt.printf("Line %2d: %q\n", i, line)
		} else {
			fmt.printf("Line %2d: FAILED\n", i)
		}
	}
}

// Add this to your insert function right before and after the insert:
debug_insert_test :: proc(pt: ^Piece_Table, position: int, text: string) {
	fmt.printf("\n############ BEFORE INSERT ############\n")
	fmt.printf("Inserting %q at position %d\n", text, position)
	debug_print_tree(pt, pt.root)
	debug_test_get_all_lines(pt)

	piece_table_insert_internal(pt, position, text)

	fmt.printf("\n############ AFTER INSERT ############\n")
	debug_print_tree(pt, pt.root)

	// Debug each piece
	if pt.root != nil {
		if pt.root.left != nil {
			debug_print_piece(pt, &pt.root.left.piece, "LEFT CHILD")
		}
		debug_print_piece(pt, &pt.root.piece, "ROOT")
		if pt.root.right != nil {
			debug_print_piece(pt, &pt.root.right.piece, "RIGHT CHILD")
		}
	}

	debug_test_get_all_lines(pt)
}


print_piece :: proc(piece: Piece) {
	fmt.printf(
		"Piece(%v, start=%d, length=%d, line_count=%d)\n",
		piece.buffer_type,
		piece.start,
		piece.length,
		piece.linefeed_count,
	)
}

print_tree_inorder :: proc(node: ^RB_Node, depth: int = 0) {
	if node == nil do return
	print_tree_inorder(node.left, depth + 1)
	indent := strings.repeat("  ", depth)
	fmt.println(indent, node)
	print_tree_inorder(node.right, depth + 1)
}

//benchmark stuff

benchmark_sequential_inserts :: proc(pt: ^Piece_Table, count: int) {
	time1 := time.tick_now()
	for i in 0 ..< count {
		piece_table_insert(pt, 5000, "hello\n")
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Sequential inserts (%d ops): %v (%.2f µs/op)\n",
		count,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

benchmark_sequential_deletes :: proc(pt: ^Piece_Table, count: int) {
	time1 := time.tick_now()
	for i in 0 ..< count {
		piece_table_delete(pt, 5, 10)
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Sequential deletes (%d ops): %v (%.2f µs/op)\n",
		count,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

benchmark_random_inserts :: proc(pt: ^Piece_Table, count: int) {

	time1 := time.tick_now()
	for i in 0 ..< count {
		pos := rand.int31_max(i32(pt.root.subtree_size))
		piece_table_insert(pt, int(pos), "test\n")
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Random inserts (%d ops): %v (%.2f µs/op)\n",
		count,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

benchmark_random_deletes :: proc(pt: ^Piece_Table, count: int) {

	time1 := time.tick_now()
	for i in 0 ..< count {
		if pt.root.subtree_size < 100 do break
		pos := rand.int31_max(i32(pt.root.subtree_size - 50))
		length := rand.int31_max(50) + 1
		piece_table_delete(pt, int(pos), int(length))
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Random deletes (%d ops): %v (%.2f µs/op)\n",
		count,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

benchmark_mixed_operations :: proc(pt: ^Piece_Table, count: int) {
	r := rand.create(54321)

	time1 := time.tick_now()
	for i in 0 ..< count {
		if rand.float32() < 0.5 {
			// Insert
			pos := rand.int31_max(i32(pt.root.subtree_size))
			piece_table_insert(pt, int(pos), "mixed\n")
		} else {
			// Delete
			if pt.root.subtree_size > 100 {
				pos := rand.int31_max(i32(pt.root.subtree_size - 20))
				length := rand.int31_max(20) + 1
				piece_table_delete(pt, int(pos), int(length))
			}
		}
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Mixed operations (%d ops): %v (%.2f µs/op)\n",
		count,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

benchmark_front_inserts :: proc(pt: ^Piece_Table, count: int) {
	time1 := time.tick_now()
	for i in 0 ..< count {
		piece_table_insert(pt, 0, "front\n")
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Front inserts (%d ops): %v (%.2f µs/op)\n",
		count,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

benchmark_end_inserts :: proc(pt: ^Piece_Table, count: int) {
	time1 := time.tick_now()
	for i in 0 ..< count {
		piece_table_insert(pt, pt.root.subtree_size, "end\n")
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"End inserts (%d ops): %v (%.2f µs/op)\n",
		count,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

benchmark_get_random_lines :: proc(pt: ^Piece_Table, count: int) {

	total_lines := pt.root.subtree_lines
	time1 := time.tick_now()
	for i in 0 ..< count {
		line_num := rand.int31_max(i32(total_lines))
		_, _ = get_line(pt, int(line_num))
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Random line reads (%d ops): %v (%.2f µs/op)\n",
		count,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

benchmark_get_all_lines :: proc(pt: ^Piece_Table) {
	total_lines := pt.root.subtree_lines
	time1 := time.tick_now()
	for i in 0 ..< total_lines {
		_, _ = get_line(pt, i)
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Sequential line reads (%d lines): %v (%.2f µs/line)\n",
		total_lines,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(total_lines),
	)
}

benchmark_large_inserts :: proc(pt: ^Piece_Table, count: int) {
	large_text := "This is a much larger piece of text that will be inserted.\nIt contains multiple lines.\nAnd more content.\n"

	time1 := time.tick_now()
	for i in 0 ..< count {
		pos := rand.int31_max(i32(pt.root.subtree_size))
		piece_table_insert(pt, int(pos), large_text)
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Large inserts (%d ops, %d bytes each): %v (%.2f µs/op)\n",
		count,
		len(large_text),
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

benchmark_pathological_splits :: proc(pt: ^Piece_Table, count: int) {
	// Insert at same position repeatedly, causing many splits
	time1 := time.tick_now()
	pos := pt.root.subtree_size / 2
	for i in 0 ..< count {
		piece_table_insert(pt, pos, "x")
	}
	time2 := time.tick_now()
	timedif := time.tick_diff(time1, time2)
	fmt.printf(
		"Pathological splits (%d ops): %v (%.2f µs/op)\n",
		count,
		timedif,
		f64(time.duration_microseconds(timedif)) / f64(count),
	)
}

run_all_benchmarks :: proc() {
	fmt.println("\n=== PIECE TABLE BENCHMARKS ===\n")

	// Warmup and initial setup
	pt := piece_table_init(#load("100k"))
	defer piece_table_destroy(&pt)

	fmt.printf("Initial size: %d bytes, %d lines\n\n", pt.root.subtree_size, pt.root.subtree_lines)

	// Basic operations
	fmt.println("--- Basic Operations (1_000_000 ops) ---")
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_sequential_inserts(&pt_temp, 1_000_000)
	}
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_sequential_deletes(&pt_temp, 1_000_000)
	}

	// Random operations
	fmt.println("\n--- Random Operations (1_000_000 ops) ---")
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_random_inserts(&pt_temp, 1_000_000)
	}
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_random_deletes(&pt_temp, 1_000_000)
	}
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_mixed_operations(&pt_temp, 1_000_000)
	}

	// Position-specific operations
	fmt.println("\n--- Position-Specific Operations (1_000_000 ops) ---")
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_front_inserts(&pt_temp, 1_000_000)
	}
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_end_inserts(&pt_temp, 1_000_000)
	}

	// Line reading
	fmt.println("\n--- Line Reading ---")
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_get_all_lines(&pt_temp)
		benchmark_get_random_lines(&pt_temp, 1_000_000)
	}

	// Large operations
	fmt.println("\n--- Large Text Operations (1_000_000 ops) ---")
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_large_inserts(&pt_temp, 1_000_000)
	}

	// Pathological cases
	fmt.println("\n--- Stress Tests (1_000_000 ops) ---")
	{
		pt_temp := piece_table_init(#load("100k"))
		defer piece_table_destroy(&pt_temp)
		benchmark_pathological_splits(&pt_temp, 1_000_000)
	}

	fmt.println("\n=== BENCHMARKS COMPLETE ===")
}

//profiling stuff
// //this part goes on main
// spall_ctx = spall.context_create("trace_test.spall")
// 	defer spall.context_destroy(&spall_ctx)

// 	buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
// 	defer delete(buffer_backing)

// 	spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
// 	defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

// 	spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)


// @(instrumentation_enter)
// spall_enter :: proc "contextless" (
// 	proc_address, call_site_return_address: rawptr,
// 	loc: runtime.Source_Code_Location,
// ) {
// 	spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
// }

// @(instrumentation_exit)
// spall_exit :: proc "contextless" (
// 	proc_address, call_site_return_address: rawptr,
// 	loc: runtime.Source_Code_Location,
// ) {
// 	spall._buffer_end(&spall_ctx, &spall_buffer)
// }
// spall_ctx: spall.Context
// @(thread_local)
// spall_buffer: spall.Buffer
