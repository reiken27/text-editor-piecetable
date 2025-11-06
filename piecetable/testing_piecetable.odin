package piecetable

import "core:fmt"
import "core:strings"

Test_Result :: struct {
	name:    string,
	passed:  bool,
	message: string,
}

test_results: [dynamic]Test_Result

@(private)
record_test :: proc(name: string, passed: bool, message := "") {
	append(&test_results, Test_Result{name, passed, message})
}

@(private)
assert_equal :: proc(name: string, expected: string, actual: string, loc := #caller_location) {
	if expected != actual {
		msg := fmt.tprintf("Expected '%s', got '%s'", expected, actual)
		record_test(name, false, msg)
		fmt.printf("[FAIL] %s: %s\n", name, msg)
	} else {
		record_test(name, true)
		fmt.printf("[PASS] %s\n", name)
	}
}

@(private)
assert_true :: proc(name: string, condition: bool, message := "", loc := #caller_location) {
	if !condition {
		record_test(name, false, message)
		fmt.printf("[FAIL] %s: %s\n", name, message)
	} else {
		record_test(name, true)
		fmt.printf("[PASS] %s\n", name)
	}
}

test_empty_document :: proc() {
	fmt.println("\n=== Test: Empty Document ===")
	pt := piece_table_init("", context.allocator)
	defer piece_table_destroy(&pt)

	line_count := get_line_count(&pt)
	assert_true("Empty doc has 0 lines", line_count == 0, fmt.tprintf("Got %d lines", line_count))

	line, ok := get_line(&pt, 0)
	assert_true("get_line(0) fails on empty doc", !ok, "Should return ok=false")
}

test_single_line_no_newline :: proc() {
	fmt.println("\n=== Test: Single Line (No Newline) ===")
	pt := piece_table_init("hello world", context.allocator)
	defer piece_table_destroy(&pt)

	line_count := get_line_count(&pt)
	assert_true("Single line has 1 line", line_count == 1, fmt.tprintf("Got %d lines", line_count))

	line, ok := get_line(&pt, 0)
	assert_true("get_line(0) succeeds", ok)
	assert_equal("Line 0 content", "hello world", line)

	_, ok2 := get_line(&pt, 1)
	assert_true("get_line(1) fails", !ok2, "Should fail for non-existent line")
}

test_single_line_with_newline :: proc() {
	fmt.println("\n=== Test: Single Line (With Newline) ===")
	pt := piece_table_init("hello world\n", context.allocator)
	defer piece_table_destroy(&pt)

	line_count := get_line_count(&pt)
	assert_true(
		"Doc with 1 newline has 2 lines",
		line_count == 2,
		fmt.tprintf("Got %d lines", line_count),
	)

	line0, ok0 := get_line(&pt, 0)
	assert_true("get_line(0) succeeds", ok0)
	assert_equal("Line 0 content", "hello world", line0)

	line1, ok1 := get_line(&pt, 1)
	assert_true("get_line(1) succeeds", ok1)
	assert_equal("Line 1 content", "", line1)
}

test_multiple_lines :: proc() {
	fmt.println("\n=== Test: Multiple Lines ===")
	text := "line 0\nline 1\nline 2"
	pt := piece_table_init(text, context.allocator)
	defer piece_table_destroy(&pt)

	line_count := get_line_count(&pt)
	assert_true("3 lines total", line_count == 3, fmt.tprintf("Got %d lines", line_count))

	line0, _ := get_line(&pt, 0)
	assert_equal("Line 0", "line 0", line0)

	line1, _ := get_line(&pt, 1)
	assert_equal("Line 1", "line 1", line1)

	line2, _ := get_line(&pt, 2)
	assert_equal("Line 2", "line 2", line2)
}

test_empty_lines :: proc() {
	fmt.println("\n=== Test: Empty Lines ===")
	text := "first\n\nthird\n"
	pt := piece_table_init(text, context.allocator)
	defer piece_table_destroy(&pt)

	line_count := get_line_count(&pt)
	assert_true("4 lines total", line_count == 4, fmt.tprintf("Got %d lines", line_count))

	line0, _ := get_line(&pt, 0)
	assert_equal("Line 0", "first", line0)

	line1, _ := get_line(&pt, 1)
	assert_equal("Line 1 (empty)", "", line1)

	line2, _ := get_line(&pt, 2)
	assert_equal("Line 2", "third", line2)

	line3, _ := get_line(&pt, 3)
	assert_equal("Line 3 (empty)", "", line3)
}

test_insert_at_start :: proc() {
	fmt.println("\n=== Test: Insert at Start ===")
	pt := piece_table_init("world\n", context.allocator)
	defer piece_table_destroy(&pt)

	piece_table_insert(&pt, 0, "hello ")

	line_count := get_line_count(&pt)
	assert_true("Still 2 lines", line_count == 2, fmt.tprintf("Got %d lines", line_count))

	line0, _ := get_line(&pt, 0)
	assert_equal("Line 0 after insert", "hello world", line0)
}

test_insert_at_end :: proc() {
	fmt.println("\n=== Test: Insert at End ===")
	pt := piece_table_init("hello", context.allocator)
	defer piece_table_destroy(&pt)

	piece_table_insert(&pt, 5, " world")

	line_count := get_line_count(&pt)
	assert_true("Still 1 line", line_count == 1, fmt.tprintf("Got %d lines", line_count))

	line0, _ := get_line(&pt, 0)
	assert_equal("Line 0 after append", "hello world", line0)
}

test_insert_in_middle :: proc() {
	fmt.println("\n=== Test: Insert in Middle ===")
	pt := piece_table_init("helloworld", context.allocator)
	defer piece_table_destroy(&pt)

	piece_table_insert(&pt, 5, " ")

	line0, _ := get_line(&pt, 0)
	assert_equal("Line 0 after insert", "hello world", line0)
}

test_insert_newline :: proc() {
	fmt.println("\n=== Test: Insert Newline ===")
	pt := piece_table_init("hello world", context.allocator)
	defer piece_table_destroy(&pt)

	piece_table_insert(&pt, 5, "\n")

	line_count := get_line_count(&pt)
	assert_true("Now 2 lines", line_count == 2, fmt.tprintf("Got %d lines", line_count))

	line0, _ := get_line(&pt, 0)
	assert_equal("Line 0", "hello", line0)

	line1, _ := get_line(&pt, 1)
	assert_equal("Line 1", " world", line1)
}

test_insert_multiple_lines :: proc() {
	fmt.println("\n=== Test: Insert Multiple Lines ===")
	pt := piece_table_init("first\nlast", context.allocator)
	defer piece_table_destroy(&pt)

	piece_table_insert(&pt, 6, "middle1\nmiddle2\n")

	line_count := get_line_count(&pt)
	assert_true("Now 4 lines", line_count == 4, fmt.tprintf("Got %d lines", line_count))

	line0, _ := get_line(&pt, 0)
	assert_equal("Line 0", "first", line0)

	line1, _ := get_line(&pt, 1)
	assert_equal("Line 1", "middle1", line1)

	line2, _ := get_line(&pt, 2)
	assert_equal("Line 2", "middle2", line2)

	line3, _ := get_line(&pt, 3)
	assert_equal("Line 3", "last", line3)
}

test_complex_inserts :: proc() {
	fmt.println("\n=== Test: Complex Multiple Inserts ===")
	pt := piece_table_init("line1\nline3\n", context.allocator)
	defer piece_table_destroy(&pt)

	// Insert line 2
	piece_table_insert(&pt, 6, "line2\n")

	// Insert at start
	piece_table_insert(&pt, 0, "line0\n")

	// Insert at very end
	piece_table_insert(&pt, pt.root.subtree_size, "line4")

	line_count := get_line_count(&pt)
	assert_true("5 lines total", line_count == 5, fmt.tprintf("Got %d lines", line_count))

	line0, _ := get_line(&pt, 0)
	assert_equal("Line 0", "line0", line0)

	line1, _ := get_line(&pt, 1)
	assert_equal("Line 1", "line1", line1)

	line2, _ := get_line(&pt, 2)
	assert_equal("Line 2", "line2", line2)

	line3, _ := get_line(&pt, 3)
	assert_equal("Line 3", "line3", line3)

	line4, _ := get_line(&pt, 4)
	assert_equal("Line 4", "line4", line4)
}

test_unicode :: proc() {
	fmt.println("\n=== Test: Unicode Content ===")
	pt := piece_table_init("Hello 世界\nΓεια σου κόσμε\n", context.allocator)
	defer piece_table_destroy(&pt)

	line_count := get_line_count(&pt)
	assert_true("3 lines with unicode", line_count == 3, fmt.tprintf("Got %d lines", line_count))

	line0, _ := get_line(&pt, 0)
	assert_equal("Unicode line 0", "Hello 世界", line0)

	line1, _ := get_line(&pt, 1)
	assert_equal("Unicode line 1", "Γεια σου κόσμε", line1)
}

test_long_line :: proc() {
	fmt.println("\n=== Test: Very Long Line ===")

	builder := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&builder)

	for i in 0 ..< 1000 {
		strings.write_string(&builder, "word ")
	}
	long_text := strings.to_string(builder)

	pt := piece_table_init(long_text, context.allocator)
	defer piece_table_destroy(&pt)

	line_count := get_line_count(&pt)
	assert_true("1 long line", line_count == 1)

	line0, ok := get_line(&pt, 0)
	assert_true("Can read long line", ok)
	assert_true("Long line has correct length", len(line0) == len(long_text))
}

test_line_spanning_pieces :: proc() {
	fmt.println("\n=== Test: Line Spanning Multiple Pieces ===")
	pt := piece_table_init("world", context.allocator)
	defer piece_table_destroy(&pt)

	piece_table_insert(&pt, 0, "hello ")
	piece_table_insert(&pt, 6, "beautiful ")

	line_count := get_line_count(&pt)
	assert_true("Still 1 line", line_count == 1)

	line0, _ := get_line(&pt, 0)
	assert_equal("Line spans 3 pieces", "hello beautiful world", line0)
}

test_delete_operations :: proc() {
	fmt.println("\n=== Test: Delete Operations ===")
	pt := piece_table_init("line0\nline1\nline2\n", context.allocator)
	defer piece_table_destroy(&pt)

	// Delete "line1\n"
	piece_table_delete(&pt, 6, 6)

	line_count := get_line_count(&pt)
	assert_true("Now 3 lines", line_count == 3, fmt.tprintf("Got %d lines", line_count))

	line0, _ := get_line(&pt, 0)
	assert_equal("Line 0 unchanged", "line0", line0)

	line1, _ := get_line(&pt, 1)
	assert_equal("Line 1 is now line2", "line2", line1)
}

run_all_tests :: proc() {
	test_results = make([dynamic]Test_Result, context.allocator)
	defer delete(test_results)

	fmt.println(
		"╔════════════════════════════════════════╗",
	)
	fmt.println("║  PIECE TABLE LINE API TEST SUITE      ║")
	fmt.println(
		"╚════════════════════════════════════════╝",
	)

	test_empty_document()
	test_single_line_no_newline()
	test_single_line_with_newline()
	test_multiple_lines()
	test_empty_lines()
	test_insert_at_start()
	test_insert_at_end()
	test_insert_in_middle()
	test_insert_newline()
	test_insert_multiple_lines()
	test_complex_inserts()
	test_unicode()
	test_long_line()
	test_line_spanning_pieces()

	fmt.println(
		"\n╔════════════════════════════════════════╗",
	)
	fmt.println("║           TEST SUMMARY                 ║")
	fmt.println(
		"╚════════════════════════════════════════╝",
	)

	passed := 0
	failed := 0
	for result in test_results {
		if result.passed {
			passed += 1
		} else {
			failed += 1
		}
	}

	fmt.printf("\nTotal: %d tests\n", len(test_results))
	fmt.printf("✓ Passed: %d\n", passed)
	if failed > 0 {
		fmt.printf("✗ Failed: %d\n", failed)
	}

	if failed == 0 {
		fmt.println("\n🎉 All tests passed!")
	} else {
		fmt.println("\n⚠️  Some tests failed. Review output above.")
	}
}
