#ifndef OSXTERM_GHOSTTY_VT_BRIDGE_H
#define OSXTERM_GHOSTTY_VT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OsXTermGhosttyTerminal OsXTermGhosttyTerminal;

typedef struct {
    uint64_t scroll_total;
    uint64_t scroll_offset;
    uint64_t scroll_viewport_length;
    uint16_t cursor_x;
    uint16_t cursor_y;
    uint8_t cursor_style;
    uint8_t cursor_flags;
    uint8_t cursor_red;
    uint8_t cursor_green;
    uint8_t cursor_blue;
} OsXTermGhosttyViewportMetadata;

enum {
    OSXTERM_GHOSTTY_CURSOR_VISIBLE = 1 << 0,
    OSXTERM_GHOSTTY_CURSOR_BLINKING = 1 << 1,
    OSXTERM_GHOSTTY_CURSOR_VIEWPORT_POSITION = 1 << 2,
    OSXTERM_GHOSTTY_CURSOR_WIDE_TAIL = 1 << 3,
    OSXTERM_GHOSTTY_CURSOR_COLOR = 1 << 4,
    OSXTERM_GHOSTTY_VIEWPORT_ACTIVE = 1 << 5,
};

OsXTermGhosttyTerminal *osxterm_ghostty_terminal_create(
    uint16_t columns,
    uint16_t rows,
    size_t max_scrollback
);

void osxterm_ghostty_terminal_destroy(OsXTermGhosttyTerminal *terminal);

void osxterm_ghostty_terminal_write(
    OsXTermGhosttyTerminal *terminal,
    const uint8_t *bytes,
    size_t length
);

int osxterm_ghostty_terminal_resize(
    OsXTermGhosttyTerminal *terminal,
    uint16_t columns,
    uint16_t rows,
    uint32_t cell_width_pixels,
    uint32_t cell_height_pixels
);

uint8_t *osxterm_ghostty_terminal_copy_text(
    OsXTermGhosttyTerminal *terminal,
    size_t *out_length
);

/*
 * Copies the visible Ghostty screen, including each cell's grapheme and
 * style, into a small versioned binary representation owned by the caller.
 * The returned buffer must be released with osxterm_ghostty_buffer_destroy.
 */
uint8_t *osxterm_ghostty_terminal_copy_styled_screen(
    OsXTermGhosttyTerminal *terminal,
    size_t *out_length
);

int osxterm_ghostty_terminal_copy_viewport_metadata(
    OsXTermGhosttyTerminal *terminal,
    OsXTermGhosttyViewportMetadata *metadata
);

void osxterm_ghostty_terminal_scroll_by(
    OsXTermGhosttyTerminal *terminal,
    int64_t rows
);

void osxterm_ghostty_terminal_scroll_to_row(
    OsXTermGhosttyTerminal *terminal,
    uint64_t row
);

void osxterm_ghostty_terminal_scroll_to_bottom(
    OsXTermGhosttyTerminal *terminal
);

uint8_t *osxterm_ghostty_terminal_copy_working_directory(
    OsXTermGhosttyTerminal *terminal,
    size_t *out_length
);

uint8_t *osxterm_ghostty_terminal_take_pty_reply(
    OsXTermGhosttyTerminal *terminal,
    size_t *out_length
);

void osxterm_ghostty_buffer_destroy(uint8_t *buffer);

#ifdef __cplusplus
}
#endif

#endif
