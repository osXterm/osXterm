#include "GhosttyVtBridge.h"

#include <ghostty/vt.h>

#include <limits.h>
#include <stdlib.h>
#include <string.h>

struct OsXTermGhosttyTerminal {
    GhosttyTerminal terminal;
    GhosttyFormatter formatter;
    GhosttyRenderState render_state;
    uint8_t *pending_pty_reply;
    size_t pending_pty_reply_length;
};

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
} OsXTermByteBuffer;

static int byte_buffer_reserve(OsXTermByteBuffer *buffer, size_t additional) {
    if (buffer == NULL || additional > SIZE_MAX - buffer->length) {
        return 0;
    }

    const size_t required = buffer->length + additional;
    if (required <= buffer->capacity) {
        return 1;
    }

    size_t capacity = buffer->capacity == 0 ? 256 : buffer->capacity;
    while (capacity < required) {
        if (capacity > SIZE_MAX / 2) {
            capacity = required;
            break;
        }
        capacity *= 2;
    }

    uint8_t *bytes = realloc(buffer->bytes, capacity);
    if (bytes == NULL) {
        return 0;
    }
    buffer->bytes = bytes;
    buffer->capacity = capacity;
    return 1;
}

static int byte_buffer_append(
    OsXTermByteBuffer *buffer,
    const void *bytes,
    size_t length
) {
    if (length == 0) {
        return 1;
    }
    if (bytes == NULL || !byte_buffer_reserve(buffer, length)) {
        return 0;
    }
    memcpy(buffer->bytes + buffer->length, bytes, length);
    buffer->length += length;
    return 1;
}

static int byte_buffer_append_u8(OsXTermByteBuffer *buffer, uint8_t value) {
    return byte_buffer_append(buffer, &value, sizeof(value));
}

static int byte_buffer_append_u16(OsXTermByteBuffer *buffer, uint16_t value) {
    const uint8_t bytes[] = {
        (uint8_t)(value & 0xff),
        (uint8_t)((value >> 8) & 0xff),
    };
    return byte_buffer_append(buffer, bytes, sizeof(bytes));
}

static void byte_buffer_write_u16(OsXTermByteBuffer *buffer, size_t offset, uint16_t value) {
    if (buffer == NULL || offset > buffer->length || buffer->length - offset < 2) {
        return;
    }
    buffer->bytes[offset] = (uint8_t)(value & 0xff);
    buffer->bytes[offset + 1] = (uint8_t)((value >> 8) & 0xff);
}

enum {
    OSXTERM_STYLED_FORMAT_VERSION = 2,
    OSXTERM_STYLED_FG_NONE = 0,
    OSXTERM_STYLED_FG_PALETTE = 1,
    OSXTERM_STYLED_FG_RGB = 2,
    OSXTERM_STYLED_BG_NONE = 0,
    OSXTERM_STYLED_BG_PALETTE = 1,
    OSXTERM_STYLED_BG_RGB = 2,
    OSXTERM_STYLED_BOLD = 1 << 0,
    OSXTERM_STYLED_ITALIC = 1 << 1,
    OSXTERM_STYLED_FAINT = 1 << 2,
    OSXTERM_STYLED_INVERSE = 1 << 3,
    OSXTERM_STYLED_INVISIBLE = 1 << 4,
    OSXTERM_STYLED_STRIKETHROUGH = 1 << 5,
    OSXTERM_STYLED_OVERLINE = 1 << 6,
    OSXTERM_STYLED_UNDERLINE = 1 << 7,
};

static uint8_t *copy_bytes(const uint8_t *bytes, size_t length, size_t *out_length) {
    if (out_length != NULL) {
        *out_length = 0;
    }

    if (bytes == NULL || length == 0) {
        return NULL;
    }

    uint8_t *copy = malloc(length);
    if (copy == NULL) {
        return NULL;
    }

    memcpy(copy, bytes, length);
    if (out_length != NULL) {
        *out_length = length;
    }
    return copy;
}

static void write_pty_reply(
    GhosttyTerminal ignored_terminal,
    void *userdata,
    const uint8_t *bytes,
    size_t length
) {
    (void)ignored_terminal;

    struct OsXTermGhosttyTerminal *terminal = userdata;
    if (terminal == NULL || bytes == NULL || length == 0) {
        return;
    }

    if (length > SIZE_MAX - terminal->pending_pty_reply_length) {
        return;
    }

    const size_t next_length = terminal->pending_pty_reply_length + length;
    uint8_t *next = realloc(terminal->pending_pty_reply, next_length);
    if (next == NULL) {
        return;
    }

    memcpy(next + terminal->pending_pty_reply_length, bytes, length);
    terminal->pending_pty_reply = next;
    terminal->pending_pty_reply_length = next_length;
}

OsXTermGhosttyTerminal *osxterm_ghostty_terminal_create(
    uint16_t columns,
    uint16_t rows,
    size_t max_scrollback
) {
    if (columns == 0 || rows == 0) {
        return NULL;
    }

    struct OsXTermGhosttyTerminal *terminal = calloc(1, sizeof(*terminal));
    if (terminal == NULL) {
        return NULL;
    }

    const GhosttyTerminalOptions options = {
        .cols = columns,
        .rows = rows,
        .max_scrollback = max_scrollback,
    };
    if (ghostty_terminal_new(NULL, &terminal->terminal, options) != GHOSTTY_SUCCESS) {
        free(terminal);
        return NULL;
    }

    GhosttyFormatterTerminalOptions formatter_options =
        GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
    formatter_options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    formatter_options.trim = true;
    if (
        ghostty_formatter_terminal_new(
            NULL,
            &terminal->formatter,
            terminal->terminal,
            formatter_options
        ) != GHOSTTY_SUCCESS
    ) {
        ghostty_terminal_free(terminal->terminal);
        free(terminal);
        return NULL;
    }

    if (
        ghostty_render_state_new(NULL, &terminal->render_state) != GHOSTTY_SUCCESS
    ) {
        ghostty_formatter_free(terminal->formatter);
        ghostty_terminal_free(terminal->terminal);
        free(terminal);
        return NULL;
    }

    if (
        ghostty_terminal_set(
            terminal->terminal,
            GHOSTTY_TERMINAL_OPT_USERDATA,
            terminal
        ) != GHOSTTY_SUCCESS
        || ghostty_terminal_set(
            terminal->terminal,
            GHOSTTY_TERMINAL_OPT_WRITE_PTY,
            (const void *)write_pty_reply
        ) != GHOSTTY_SUCCESS
    ) {
        ghostty_render_state_free(terminal->render_state);
        ghostty_formatter_free(terminal->formatter);
        ghostty_terminal_free(terminal->terminal);
        free(terminal);
        return NULL;
    }

    return terminal;
}

void osxterm_ghostty_terminal_destroy(OsXTermGhosttyTerminal *terminal) {
    if (terminal == NULL) {
        return;
    }

    ghostty_render_state_free(terminal->render_state);
    ghostty_formatter_free(terminal->formatter);
    ghostty_terminal_free(terminal->terminal);
    free(terminal->pending_pty_reply);
    free(terminal);
}

void osxterm_ghostty_terminal_write(
    OsXTermGhosttyTerminal *terminal,
    const uint8_t *bytes,
    size_t length
) {
    if (terminal == NULL || bytes == NULL || length == 0) {
        return;
    }

    ghostty_terminal_vt_write(terminal->terminal, bytes, length);
}

int osxterm_ghostty_terminal_resize(
    OsXTermGhosttyTerminal *terminal,
    uint16_t columns,
    uint16_t rows,
    uint32_t cell_width_pixels,
    uint32_t cell_height_pixels
) {
    if (terminal == NULL || columns == 0 || rows == 0) {
        return 0;
    }

    return ghostty_terminal_resize(
        terminal->terminal,
        columns,
        rows,
        cell_width_pixels,
        cell_height_pixels
    ) == GHOSTTY_SUCCESS;
}

uint8_t *osxterm_ghostty_terminal_copy_text(
    OsXTermGhosttyTerminal *terminal,
    size_t *out_length
) {
    if (out_length != NULL) {
        *out_length = 0;
    }
    if (terminal == NULL) {
        return NULL;
    }

    uint8_t *formatted = NULL;
    size_t formatted_length = 0;
    if (
        ghostty_formatter_format_alloc(
            terminal->formatter,
            NULL,
            &formatted,
            &formatted_length
        ) != GHOSTTY_SUCCESS
    ) {
        return NULL;
    }

    uint8_t *copy = copy_bytes(formatted, formatted_length, out_length);
    ghostty_free(NULL, formatted, formatted_length);
    return copy;
}

static int append_styled_color(
    OsXTermByteBuffer *buffer,
    uint8_t kind,
    const GhosttyStyleColor *style_color,
    const GhosttyColorRgb *resolved_color
) {
    if (kind == OSXTERM_STYLED_FG_PALETTE || kind == OSXTERM_STYLED_BG_PALETTE) {
        if (style_color == NULL) {
            return 0;
        }
        return byte_buffer_append_u8(buffer, style_color->value.palette);
    }
    if (kind == OSXTERM_STYLED_FG_RGB || kind == OSXTERM_STYLED_BG_RGB) {
        if (resolved_color == NULL) {
            return 0;
        }
        return byte_buffer_append(buffer, resolved_color, sizeof(*resolved_color));
    }
    return 1;
}

uint8_t *osxterm_ghostty_terminal_copy_styled_screen(
    OsXTermGhosttyTerminal *terminal,
    size_t *out_length
) {
    if (out_length != NULL) {
        *out_length = 0;
    }
    if (terminal == NULL || terminal->render_state == NULL) {
        return NULL;
    }

    if (
        ghostty_render_state_update(
            terminal->render_state,
            terminal->terminal
        ) != GHOSTTY_SUCCESS
    ) {
        return NULL;
    }

    uint16_t row_count = 0;
    if (
        ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_ROWS,
            &row_count
        ) != GHOSTTY_SUCCESS
    ) {
        return NULL;
    }

    GhosttyRenderStateRowIterator rows = NULL;
    if (
        ghostty_render_state_row_iterator_new(NULL, &rows) != GHOSTTY_SUCCESS
        || ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            &rows
        ) != GHOSTTY_SUCCESS
    ) {
        ghostty_render_state_row_iterator_free(rows);
        return NULL;
    }

    OsXTermByteBuffer output = {0};
    const uint8_t header[] = {
        'M', 'X', 'S', 'C', OSXTERM_STYLED_FORMAT_VERSION, 0, 0,
    };
    if (!byte_buffer_append(&output, header, sizeof(header))) {
        ghostty_render_state_row_iterator_free(rows);
        free(output.bytes);
        return NULL;
    }
    byte_buffer_write_u16(&output, 5, row_count);

    uint16_t encoded_rows = 0;
    while (ghostty_render_state_row_iterator_next(rows)) {
        if (encoded_rows == UINT16_MAX) {
            free(output.bytes);
            ghostty_render_state_row_iterator_free(rows);
            return NULL;
        }

        const size_t cell_count_offset = output.length;
        if (!byte_buffer_append_u16(&output, 0)) {
            free(output.bytes);
            ghostty_render_state_row_iterator_free(rows);
            return NULL;
        }

        GhosttyRenderStateRowCells cells = NULL;
        if (
            ghostty_render_state_row_cells_new(NULL, &cells) != GHOSTTY_SUCCESS
            || ghostty_render_state_row_get(
                rows,
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                &cells
            ) != GHOSTTY_SUCCESS
        ) {
            ghostty_render_state_row_cells_free(cells);
            free(output.bytes);
            ghostty_render_state_row_iterator_free(rows);
            return NULL;
        }

        uint16_t encoded_cells = 0;
        while (ghostty_render_state_row_cells_next(cells)) {
            if (encoded_cells == UINT16_MAX) {
                ghostty_render_state_row_cells_free(cells);
                free(output.bytes);
                ghostty_render_state_row_iterator_free(rows);
                return NULL;
            }

            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            if (
                ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                    &style
                ) != GHOSTTY_SUCCESS
            ) {
                ghostty_style_default(&style);
            }

            GhosttyColorRgb resolved_fg = {0};
            GhosttyColorRgb resolved_bg = {0};
            const int has_resolved_fg =
                ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                    &resolved_fg
                ) == GHOSTTY_SUCCESS;
            const int has_resolved_bg =
                ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                    &resolved_bg
                ) == GHOSTTY_SUCCESS;

            uint8_t fg_kind = OSXTERM_STYLED_FG_NONE;
            const GhosttyColorRgb *fg_rgb = NULL;
            if (style.fg_color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
                fg_kind = OSXTERM_STYLED_FG_PALETTE;
            } else if (style.fg_color.tag == GHOSTTY_STYLE_COLOR_RGB) {
                fg_kind = OSXTERM_STYLED_FG_RGB;
                fg_rgb = &style.fg_color.value.rgb;
            } else if (has_resolved_fg) {
                fg_kind = OSXTERM_STYLED_FG_RGB;
                fg_rgb = &resolved_fg;
            }

            uint8_t bg_kind = OSXTERM_STYLED_BG_NONE;
            const GhosttyColorRgb *bg_rgb = NULL;
            if (style.bg_color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
                bg_kind = OSXTERM_STYLED_BG_PALETTE;
            } else if (style.bg_color.tag == GHOSTTY_STYLE_COLOR_RGB) {
                bg_kind = OSXTERM_STYLED_BG_RGB;
                bg_rgb = &style.bg_color.value.rgb;
            } else if (has_resolved_bg) {
                bg_kind = OSXTERM_STYLED_BG_RGB;
                bg_rgb = &resolved_bg;
            }

            uint8_t style_flags = 0;
            if (style.bold) style_flags |= OSXTERM_STYLED_BOLD;
            if (style.italic) style_flags |= OSXTERM_STYLED_ITALIC;
            if (style.faint) style_flags |= OSXTERM_STYLED_FAINT;
            if (style.inverse) style_flags |= OSXTERM_STYLED_INVERSE;
            if (style.invisible) style_flags |= OSXTERM_STYLED_INVISIBLE;
            if (style.strikethrough) style_flags |= OSXTERM_STYLED_STRIKETHROUGH;
            if (style.overline) style_flags |= OSXTERM_STYLED_OVERLINE;
            if (style.underline != GHOSTTY_SGR_UNDERLINE_NONE) {
                style_flags |= OSXTERM_STYLED_UNDERLINE;
            }

            uint32_t graphemes_len = 0;
            if (
                ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                    &graphemes_len
                ) != GHOSTTY_SUCCESS
            ) {
                graphemes_len = 0;
            }

            GhosttyBuffer graphemes = {0};
            uint8_t *grapheme_bytes = NULL;
            if (graphemes_len > 0) {
                const GhosttyResult size_result =
                    ghostty_render_state_row_cells_get(
                        cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                        &graphemes
                    );
                if (size_result != GHOSTTY_OUT_OF_SPACE || graphemes.len > UINT16_MAX) {
                    free(grapheme_bytes);
                    ghostty_render_state_row_cells_free(cells);
                    free(output.bytes);
                    ghostty_render_state_row_iterator_free(rows);
                    return NULL;
                }
                grapheme_bytes = malloc(graphemes.len);
                if (grapheme_bytes == NULL) {
                    ghostty_render_state_row_cells_free(cells);
                    free(output.bytes);
                    ghostty_render_state_row_iterator_free(rows);
                    return NULL;
                }
                graphemes.ptr = grapheme_bytes;
                graphemes.cap = graphemes.len;
                if (
                    ghostty_render_state_row_cells_get(
                        cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                        &graphemes
                    ) != GHOSTTY_SUCCESS
                ) {
                    free(grapheme_bytes);
                    ghostty_render_state_row_cells_free(cells);
                    free(output.bytes);
                    ghostty_render_state_row_iterator_free(rows);
                    return NULL;
                }
            }

            uint8_t column_span = 1;
            GhosttyCell raw_cell = 0;
            if (
                ghostty_render_state_row_cells_get(
                    cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                    &raw_cell
                ) == GHOSTTY_SUCCESS
            ) {
                GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
                if (
                    ghostty_cell_get(
                        raw_cell,
                        GHOSTTY_CELL_DATA_WIDE,
                        &wide
                    ) == GHOSTTY_SUCCESS
                ) {
                    switch (wide) {
                    case GHOSTTY_CELL_WIDE_WIDE:
                        column_span = 2;
                        break;
                    case GHOSTTY_CELL_WIDE_SPACER_TAIL:
                    case GHOSTTY_CELL_WIDE_SPACER_HEAD:
                        column_span = 0;
                        break;
                    case GHOSTTY_CELL_WIDE_NARROW:
                    default:
                        column_span = 1;
                        break;
                    }
                }
            }

            const uint8_t color_flags = (uint8_t)(fg_kind | (bg_kind << 2));
            const int encoded =
                byte_buffer_append_u16(&output, (uint16_t)graphemes.len)
                && byte_buffer_append(&output, graphemes.ptr, graphemes.len)
                && byte_buffer_append_u8(&output, style_flags)
                && byte_buffer_append_u8(&output, color_flags)
                && byte_buffer_append_u8(&output, (uint8_t)style.underline)
                && byte_buffer_append_u8(&output, column_span)
                && append_styled_color(
                    &output,
                    fg_kind,
                    &style.fg_color,
                    fg_rgb
                )
                && append_styled_color(
                    &output,
                    bg_kind,
                    &style.bg_color,
                    bg_rgb
                );
            free(grapheme_bytes);
            if (!encoded) {
                ghostty_render_state_row_cells_free(cells);
                free(output.bytes);
                ghostty_render_state_row_iterator_free(rows);
                return NULL;
            }
            encoded_cells += 1;
        }

        ghostty_render_state_row_cells_free(cells);
        byte_buffer_write_u16(&output, cell_count_offset, encoded_cells);
        encoded_rows += 1;
    }

    ghostty_render_state_row_iterator_free(rows);
    byte_buffer_write_u16(&output, 5, encoded_rows);
    if (output.length == 0) {
        free(output.bytes);
        return NULL;
    }
    if (out_length != NULL) {
        *out_length = output.length;
    }
    return output.bytes;
}

int osxterm_ghostty_terminal_copy_viewport_metadata(
    OsXTermGhosttyTerminal *terminal,
    OsXTermGhosttyViewportMetadata *metadata
) {
    if (terminal == NULL || metadata == NULL || terminal->render_state == NULL) {
        return 0;
    }

    memset(metadata, 0, sizeof(*metadata));
    if (
        ghostty_render_state_update(
            terminal->render_state,
            terminal->terminal
        ) != GHOSTTY_SUCCESS
    ) {
        return 0;
    }

    GhosttyTerminalScrollbar scrollbar = {0};
    if (
        ghostty_terminal_get(
            terminal->terminal,
            GHOSTTY_TERMINAL_DATA_SCROLLBAR,
            &scrollbar
        ) != GHOSTTY_SUCCESS
    ) {
        return 0;
    }
    metadata->scroll_total = scrollbar.total;
    metadata->scroll_offset = scrollbar.offset;
    metadata->scroll_viewport_length = scrollbar.len;

    bool cursor_visible = false;
    bool cursor_blinking = false;
    bool cursor_viewport_has_value = false;
    bool cursor_wide_tail = false;
    GhosttyRenderStateCursorVisualStyle cursor_style =
        GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
    uint16_t cursor_x = 0;
    uint16_t cursor_y = 0;

    if (
        ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE,
            &cursor_visible
        ) == GHOSTTY_SUCCESS
    ) {
        if (cursor_visible) {
            metadata->cursor_flags |= OSXTERM_GHOSTTY_CURSOR_VISIBLE;
        }
    }
    if (
        ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING,
            &cursor_blinking
        ) == GHOSTTY_SUCCESS
        && cursor_blinking
    ) {
        metadata->cursor_flags |= OSXTERM_GHOSTTY_CURSOR_BLINKING;
    }
    if (
        ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE,
            &cursor_viewport_has_value
        ) == GHOSTTY_SUCCESS
        && cursor_viewport_has_value
        && ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X,
            &cursor_x
        ) == GHOSTTY_SUCCESS
        && ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y,
            &cursor_y
        ) == GHOSTTY_SUCCESS
    ) {
        metadata->cursor_flags |= OSXTERM_GHOSTTY_CURSOR_VIEWPORT_POSITION;
        metadata->cursor_x = cursor_x;
        metadata->cursor_y = cursor_y;
    }
    if (
        ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL,
            &cursor_wide_tail
        ) == GHOSTTY_SUCCESS
        && cursor_wide_tail
    ) {
        metadata->cursor_flags |= OSXTERM_GHOSTTY_CURSOR_WIDE_TAIL;
    }
    if (
        ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
            &cursor_style
        ) == GHOSTTY_SUCCESS
    ) {
        metadata->cursor_style = (uint8_t)cursor_style;
    }

    bool viewport_active = false;
    if (
        ghostty_terminal_get(
            terminal->terminal,
            GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE,
            &viewport_active
        ) == GHOSTTY_SUCCESS
        && viewport_active
    ) {
        metadata->cursor_flags |= OSXTERM_GHOSTTY_VIEWPORT_ACTIVE;
    }

    bool has_cursor_color = false;
    GhosttyColorRgb cursor_color = {0};
    if (
        ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE,
            &has_cursor_color
        ) == GHOSTTY_SUCCESS
        && has_cursor_color
        && ghostty_render_state_get(
            terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR,
            &cursor_color
        ) == GHOSTTY_SUCCESS
    ) {
        metadata->cursor_flags |= OSXTERM_GHOSTTY_CURSOR_COLOR;
        metadata->cursor_red = cursor_color.r;
        metadata->cursor_green = cursor_color.g;
        metadata->cursor_blue = cursor_color.b;
    }

    return 1;
}

void osxterm_ghostty_terminal_scroll_by(
    OsXTermGhosttyTerminal *terminal,
    int64_t rows
) {
    if (terminal == NULL || rows == 0) {
        return;
    }

    GhosttyTerminalScrollViewport behavior = {0};
    behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA;
    behavior.value.delta = (intptr_t)rows;
    ghostty_terminal_scroll_viewport(terminal->terminal, behavior);
}

void osxterm_ghostty_terminal_scroll_to_bottom(
    OsXTermGhosttyTerminal *terminal
) {
    if (terminal == NULL) {
        return;
    }

    GhosttyTerminalScrollViewport behavior = {0};
    behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM;
    ghostty_terminal_scroll_viewport(terminal->terminal, behavior);
}

void osxterm_ghostty_terminal_scroll_to_row(
    OsXTermGhosttyTerminal *terminal,
    uint64_t row
) {
    if (terminal == NULL) {
        return;
    }

    GhosttyTerminalScrollViewport behavior = {0};
    behavior.tag = GHOSTTY_SCROLL_VIEWPORT_ROW;
    behavior.value.row = (size_t)row;
    ghostty_terminal_scroll_viewport(terminal->terminal, behavior);
}

uint8_t *osxterm_ghostty_terminal_copy_working_directory(
    OsXTermGhosttyTerminal *terminal,
    size_t *out_length
) {
    if (out_length != NULL) {
        *out_length = 0;
    }
    if (terminal == NULL) {
        return NULL;
    }

    GhosttyString working_directory = {0};
    if (
        ghostty_terminal_get(
            terminal->terminal,
            GHOSTTY_TERMINAL_DATA_PWD,
            &working_directory
        ) != GHOSTTY_SUCCESS
    ) {
        return NULL;
    }

    return copy_bytes(working_directory.ptr, working_directory.len, out_length);
}

uint8_t *osxterm_ghostty_terminal_take_pty_reply(
    OsXTermGhosttyTerminal *terminal,
    size_t *out_length
) {
    if (out_length != NULL) {
        *out_length = 0;
    }
    if (terminal == NULL || terminal->pending_pty_reply_length == 0) {
        return NULL;
    }

    uint8_t *reply = terminal->pending_pty_reply;
    if (out_length != NULL) {
        *out_length = terminal->pending_pty_reply_length;
    }
    terminal->pending_pty_reply = NULL;
    terminal->pending_pty_reply_length = 0;
    return reply;
}

void osxterm_ghostty_buffer_destroy(uint8_t *buffer) {
    free(buffer);
}
