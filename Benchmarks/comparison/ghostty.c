// Feeds one comparison workload to libghostty-vt and reports pass times and the final screen.
// Usage: ghostty WORKLOAD COLUMNS ROWS CHUNK WARMUPS PASSES HISTORY
#include <dlfcn.h>
#include <ghostty/vt.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void fail(const char *message) {
  fprintf(stderr, "ghostty runner: %s\n", message);
  exit(1);
}

static GhosttyTerminal make_terminal(uint16_t columns, uint16_t rows, size_t history) {
  GhosttyTerminal terminal = NULL;
  if (ghostty_terminal_new(NULL, &terminal, columns, rows) != GHOSTTY_SUCCESS) fail("terminal_new");
  // Keep history by line count alone, like the other cores. The default byte cap holds about one page.
  size_t unlimited = SIZE_MAX;
  if (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unlimited) != GHOSTTY_SUCCESS)
    fail("scrollback bytes");
  if (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &history) != GHOSTTY_SUCCESS)
    fail("scrollback lines");
  return terminal;
}

static void feed(GhosttyTerminal terminal, const uint8_t *bytes, size_t length, size_t chunk) {
  for (size_t offset = 0; offset < length; offset += chunk) {
    size_t count = length - offset < chunk ? length - offset : chunk;
    ghostty_terminal_vt_write(terminal, bytes + offset, count);
  }
}

static void put_utf8(uint32_t scalar) {
  char out[4];
  int count;
  if (scalar < 0x80) {
    if (scalar == '"' || scalar == '\\') { putchar('\\'); putchar((int)scalar); return; }
    if (scalar < 0x20) { printf("\\u%04x", scalar); return; }
    out[0] = (char)scalar; count = 1;
  } else if (scalar < 0x800) {
    out[0] = (char)(0xC0 | (scalar >> 6)); out[1] = (char)(0x80 | (scalar & 0x3F)); count = 2;
  } else if (scalar < 0x10000) {
    out[0] = (char)(0xE0 | (scalar >> 12)); out[1] = (char)(0x80 | ((scalar >> 6) & 0x3F));
    out[2] = (char)(0x80 | (scalar & 0x3F)); count = 3;
  } else {
    out[0] = (char)(0xF0 | (scalar >> 18)); out[1] = (char)(0x80 | ((scalar >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((scalar >> 6) & 0x3F)); out[3] = (char)(0x80 | (scalar & 0x3F)); count = 4;
  }
  fwrite(out, 1, (size_t)count, stdout);
}

static void print_state(GhosttyTerminal terminal, uint16_t columns, uint16_t rows) {
  uint16_t x = 0, y = 0;
  size_t history = 0;
  GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x);
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y);
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &history);
  ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
  printf("\"state\":{\"cursor\":[%u,%u],\"history\":%zu,\"alternate\":%s,\"rows\":[", y, x, history,
         screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE ? "true" : "false");
  for (uint16_t row = 0; row < rows; row++) {
    printf(row ? ",\"" : "\"");
    for (uint16_t column = 0; column < columns; column++) {
      GhosttyPoint point = {.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {.x = column, .y = row}}};
      GhosttyGridRef ref;
      GhosttyCell cell;
      if (ghostty_terminal_grid_ref(terminal, point, &ref) != GHOSTTY_SUCCESS) fail("grid_ref");
      if (ghostty_grid_ref_cell(&ref, &cell) != GHOSTTY_SUCCESS) fail("grid_ref_cell");
      GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
      ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
      if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;
      uint32_t scalars[16];
      size_t count = 0;
      if (ghostty_grid_ref_graphemes(&ref, scalars, 16, &count) != GHOSTTY_SUCCESS) fail("graphemes");
      if (count == 0) putchar(' ');
      for (size_t i = 0; i < count; i++) put_utf8(scalars[i]);
    }
    putchar('"');
  }
  printf("]}");
}

int main(int argc, char **argv) {
  if (argc != 8) fail("usage: ghostty WORKLOAD COLUMNS ROWS CHUNK WARMUPS PASSES HISTORY");
  FILE *file = fopen(argv[1], "rb");
  if (!file) fail("cannot open workload");
  fseek(file, 0, SEEK_END);
  size_t length = (size_t)ftell(file);
  fseek(file, 0, SEEK_SET);
  uint8_t *bytes = malloc(length);
  if (fread(bytes, 1, length, file) != length) fail("short read");
  fclose(file);
  uint16_t columns = (uint16_t)atoi(argv[2]), rows = (uint16_t)atoi(argv[3]);
  size_t chunk = (size_t)atol(argv[4]), history = (size_t)atol(argv[7]);
  int warmups = atoi(argv[5]), passes = atoi(argv[6]);
  uint64_t (*allocations)(void) = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "comparison_allocations");

  mach_timebase_info_data_t timebase;
  mach_timebase_info(&timebase);
  for (int i = 0; i < warmups; i++) {
    GhosttyTerminal terminal = make_terminal(columns, rows, history);
    feed(terminal, bytes, length, chunk);
    ghostty_terminal_free(terminal);
  }
  printf("{\"passes\":[");
  GhosttyTerminal last = NULL;
  for (int i = 0; i < passes; i++) {
    if (last) ghostty_terminal_free(last);
    last = make_terminal(columns, rows, history);
    uint64_t allocated = allocations ? allocations() : 0;
    uint64_t start = mach_absolute_time();
    feed(last, bytes, length, chunk);
    uint64_t wall = (mach_absolute_time() - start) * timebase.numer / timebase.denom;
    printf(i ? ",{" : "{");
    printf("\"wall\":%llu", (unsigned long long)wall);
    if (allocations) printf(",\"allocations\":%llu", (unsigned long long)(allocations() - allocated));
    printf("}");
  }
  printf("],");
  print_state(last, columns, rows);
  printf("}\n");
  ghostty_terminal_free(last);
  free(bytes);
  return 0;
}
