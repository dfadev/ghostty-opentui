import {
  TextBufferRenderable,
  type TextBufferOptions,
  FrameBufferRenderable,
  type FrameBufferOptions,
  StyledText,
  RGBA,
  type RenderContext,
  type TextChunk,
  type OptimizedBuffer,
} from "@opentui/core";
import {
  ptyToJson,
  PersistentTerminal,
  hasPersistentTerminalSupport,
  type TerminalData,
  type TerminalSpan,
  StyleFlags,
} from "./ffi.js";
import wcwidth from "wcwidth";

const colorCache = new Map<string, RGBA>();

function cachedColor(hex: string): RGBA {
  let c = colorCache.get(hex);
  if (c) return c;
  c = RGBA.fromHex(hex);
  colorCache.set(hex, c);
  return c;
}

const DEFAULT_FG = cachedColor("#d4d4d4");
const DEFAULT_BG = cachedColor("#1e1e1e");

type WidthAwareChunk = TextChunk & {
  cellWidth: number;
};

function getChunkCellWidth(chunk: TextChunk): number {
  return "cellWidth" in chunk &&
    typeof (chunk as WidthAwareChunk).cellWidth === "number"
    ? (chunk as WidthAwareChunk).cellWidth
    : wcwidth(chunk.text);
}

function cellColToStringIndex(text: string, cellCol: number): number {
  if (cellCol <= 0) return 0;
  let col = 0;
  let strIdx = 0;
  for (const ch of text) {
    if (col >= cellCol) break;
    col += wcwidth(ch);
    strIdx += ch.length;
  }
  return strIdx;
}

/**
 * Defines a region to highlight in the terminal output.
 */
export interface HighlightRegion {
  /** Line number (0-based) */
  line: number;
  /** Start column (0-based, inclusive) */
  start: number;
  /** End column (0-based, exclusive) */
  end: number;
  /** If true, replaces the highlighted text with 'x' characters (for testing) */
  replaceWithX?: boolean;
  /** Background color for the highlight (hex string like "#ff0000") */
  backgroundColor: string;
}

const TextAttributes = {
  BOLD: 1 << 0,
  DIM: 1 << 1,
  ITALIC: 1 << 2,
  UNDERLINE: 1 << 3,
  BLINK: 1 << 4,
  REVERSE: 1 << 5,
  HIDDEN: 1 << 6,
  STRIKETHROUGH: 1 << 7,
};

interface LineInfoWithStarts {
  lineStarts?: number[];
  lineStartCols?: number[];
}

function getLineStarts(lineInfo: LineInfoWithStarts): number[] {
  return lineInfo.lineStarts ?? lineInfo.lineStartCols ?? [];
}

function convertSpanToChunk(span: TerminalSpan): WidthAwareChunk {
  const { text, fg, bg, flags, width } = span;

  let fgColor = fg ? cachedColor(fg) : DEFAULT_FG;
  let bgColor = bg ? cachedColor(bg) : undefined;

  if (flags & StyleFlags.INVERSE) {
    const temp = fgColor;
    fgColor = bgColor || DEFAULT_BG;
    bgColor = temp;
  }

  let attributes = 0;
  if (flags & StyleFlags.BOLD) attributes |= TextAttributes.BOLD;
  if (flags & StyleFlags.ITALIC) attributes |= TextAttributes.ITALIC;
  if (flags & StyleFlags.UNDERLINE) attributes |= TextAttributes.UNDERLINE;
  if (flags & StyleFlags.STRIKETHROUGH)
    attributes |= TextAttributes.STRIKETHROUGH;
  if (flags & StyleFlags.FAINT) attributes |= TextAttributes.DIM;

  return {
    __isChunk: true,
    text,
    fg: fgColor,
    bg: bgColor,
    attributes,
    cellWidth: width,
  };
}

/**
 * Applies highlights to chunks for a specific line.
 * Splits chunks at highlight boundaries and applies background colors.
 */
export function applyHighlightsToLine(
  chunks: TextChunk[],
  highlights: HighlightRegion[],
): TextChunk[] {
  if (highlights.length === 0) return chunks;

  const result: TextChunk[] = [];
  let col = 0;

  for (const chunk of chunks) {
    const w = getChunkCellWidth(chunk);
    const chunkStart = col;
    const chunkEnd = col + w;

    // Find all highlights that overlap with this chunk
    const overlapping = highlights
      .filter((hl) => hl.start < chunkEnd && hl.end > chunkStart)
      .sort((a, b) => a.start - b.start);

    if (overlapping.length === 0) {
      result.push(chunk);
      col = chunkEnd;
      continue;
    }

    // Split chunk at highlight boundaries
    let cellPos = 0;

    for (const hl of overlapping) {
      const hlStartLocal = Math.max(0, hl.start - chunkStart);
      const hlEndLocal = Math.min(w, hl.end - chunkStart);

      // Text before highlight
      if (cellPos < hlStartLocal) {
        const startStr = cellColToStringIndex(chunk.text, cellPos);
        const endStr = cellColToStringIndex(chunk.text, hlStartLocal);
        result.push({
          ...chunk,
          text: chunk.text.slice(startStr, endStr),
          cellWidth: hlStartLocal - cellPos,
        } as TextChunk);
      }

      // Highlighted text
      if (hlStartLocal < hlEndLocal) {
        const startStr = cellColToStringIndex(chunk.text, hlStartLocal);
        const endStr = cellColToStringIndex(chunk.text, hlEndLocal);
        const hlText = chunk.text.slice(startStr, endStr);
        const cellWidth = hlEndLocal - hlStartLocal;
        result.push({
          ...chunk,
          text: hl.replaceWithX ? "x".repeat(cellWidth) : hlText,
          bg: RGBA.fromHex(hl.backgroundColor),
          cellWidth,
        } as TextChunk);
      }

      cellPos = hlEndLocal;
    }

    // Text after last highlight
    if (cellPos < w) {
      const startStr = cellColToStringIndex(chunk.text, cellPos);
      result.push({
        ...chunk,
        text: chunk.text.slice(startStr),
        cellWidth: w - cellPos,
      } as TextChunk);
    }

    col = chunkEnd;
  }

  return result;
}

export interface CursorStyle {
  /** Whether to show the cursor */
  visible?: boolean;
  /** Cursor style: 'block' inverts colors, 'underline' adds underline attribute */
  style?: "block" | "underline";
}

/**
 * Creates a cursor-styled chunk.
 */
function makeCursorChunk(
  char: string,
  style: "block" | "underline",
  original?: TextChunk,
): WidthAwareChunk {
  const cellWidth = Math.max(1, wcwidth(char));

  if (style === "block") {
    return {
      __isChunk: true,
      text: char,
      fg: original?.bg || cachedColor("#1e1e1e"),
      bg: original?.fg || DEFAULT_FG,
      attributes: original?.attributes ?? 0,
      cellWidth,
    };
  }
  return {
    __isChunk: true,
    text: char,
    fg: original?.fg || DEFAULT_FG,
    bg: original?.bg,
    attributes: (original?.attributes ?? 0) | TextAttributes.UNDERLINE,
    cellWidth,
  };
}

/**
 * Applies cursor styling to chunks for a specific line.
 * For 'block' style, inverts fg/bg colors at cursor position.
 * For 'underline' style, adds underline attribute.
 */
function applyCursorToLine(
  chunks: TextChunk[],
  cursorX: number,
  cursorStyle: "block" | "underline",
): TextChunk[] {
  const totalLen = chunks.reduce(
    (sum, chunk) => sum + getChunkCellWidth(chunk),
    0,
  );

  // Cursor beyond line content - pad with spaces then append cursor
  if (cursorX >= totalLen) {
    const gap = cursorX - totalLen;
    if (gap > 0) {
      return [
        ...chunks,
        {
          __isChunk: true,
          text: " ".repeat(gap),
          attributes: 0,
          cellWidth: gap,
        } as WidthAwareChunk,
        makeCursorChunk(" ", cursorStyle),
      ];
    }
    return [...chunks, makeCursorChunk(" ", cursorStyle)];
  }

  // Find and split the chunk containing the cursor
  const result: TextChunk[] = [];
  let col = 0;

  for (const chunk of chunks) {
    const w = getChunkCellWidth(chunk);
    const chunkEnd = col + w;

    if (cursorX >= col && cursorX < chunkEnd) {
      const localCol = cursorX - col;
      const strIdx = cellColToStringIndex(chunk.text, localCol);
      const cursorChar = String.fromCodePoint(chunk.text.codePointAt(strIdx)!);
      const strEnd = strIdx + cursorChar.length;

      if (strIdx > 0) {
        result.push({ ...chunk, text: chunk.text.slice(0, strIdx) });
      }
      result.push(makeCursorChunk(cursorChar, cursorStyle, chunk));
      if (strEnd < chunk.text.length) {
        result.push({ ...chunk, text: chunk.text.slice(strEnd) });
      }
    } else {
      result.push(chunk);
    }

    col = chunkEnd;
  }

  return result;
}

export function terminalDataToStyledText(
  data: TerminalData,
  highlights?: HighlightRegion[],
  cursor?: { x: number; y: number; style: "block" | "underline" },
): StyledText {
  const chunks: TextChunk[] = [];

  // Group highlights by line for efficient lookup
  const highlightsByLine = new Map<number, HighlightRegion[]>();
  if (highlights) {
    for (const hl of highlights) {
      const lineHighlights = highlightsByLine.get(hl.line) ?? [];
      lineHighlights.push(hl);
      highlightsByLine.set(hl.line, lineHighlights);
    }
  }

  for (let i = 0; i < data.lines.length; i++) {
    const line = data.lines[i];
    let lineChunks: TextChunk[] = [];

    if (line.spans.length === 0) {
      lineChunks.push({ __isChunk: true, text: " ", attributes: 0 });
    } else {
      for (const span of line.spans) {
        lineChunks.push(convertSpanToChunk(span));
      }
    }

    // Apply highlights for this line
    const lineHighlights = highlightsByLine.get(i);
    if (lineHighlights) {
      lineChunks = applyHighlightsToLine(lineChunks, lineHighlights);
    }

    // Apply cursor for this line
    if (cursor && i === cursor.y) {
      lineChunks = applyCursorToLine(lineChunks, cursor.x, cursor.style);
    }

    chunks.push(...lineChunks);

    if (i < data.lines.length - 1) {
      chunks.push({ __isChunk: true, text: "\n", attributes: 0 });
    }
  }

  return new StyledText(chunks);
}

export interface GhosttyTerminalOptions extends TextBufferOptions {
  ansi?: string | Buffer | Uint8Array;
  cols?: number;
  rows?: number;
  limit?: number; // Maximum number of lines to render (from start)
  trimEnd?: boolean; // Remove empty lines from the end
  highlights?: HighlightRegion[]; // Regions to highlight with custom background colors
  /**
   * Enable persistent mode for streaming/interactive use cases.
   * When true, the terminal maintains state between feed() calls.
   * Much more efficient for streaming than updating the ansi prop repeatedly.
   */
  persistent?: boolean;
  /**
   * Show the terminal cursor. Defaults to false.
   */
  showCursor?: boolean;
  /**
   * Cursor style: 'block' or 'underline'. When omitted, the terminal's
   * native cursor style is preserved (e.g. bar set via DECSCUSR).
   */
  cursorStyle?: "block" | "underline";
  /**
   * Whether this component participates in focus management.
   * When true, cursor rendering is gated on focus state.
   */
  focusable?: boolean;
}

/** @deprecated Use GhosttyTerminalOptions instead */
export type TerminalBufferOptions = GhosttyTerminalOptions;

export class GhosttyTerminalRenderable extends TextBufferRenderable {
  private _ansi: string | Buffer | Uint8Array;
  private _cols: number;
  private _rows: number;
  private _limit?: number;
  private _trimEnd?: boolean;
  private _highlights?: HighlightRegion[];
  private _ansiDirty: boolean = false;
  private _lineCount: number = 0;
  private _scrollOffset?: number;
  private _showCursor: boolean = false;
  private _cursorStyle: "block" | "underline" | undefined = undefined;
  private _renderCursor = {
    x: 0,
    y: 0,
    visible: false,
    style: "default" as "default" | "block" | "line" | "underline",
  };

  // Persistent terminal support
  private _persistent: boolean = false;
  private _persistentTerminal: PersistentTerminal | null = null;

  constructor(ctx: RenderContext, options: GhosttyTerminalOptions) {
    super(ctx, {
      ...options,
      fg: DEFAULT_FG,
      wrapMode: "none",
    });

    this._ansi = options.ansi ?? "";
    this._cols = options.cols ?? 120;
    this._rows = options.rows ?? 40;
    this._limit = options.limit;
    this._trimEnd = options.trimEnd;
    this._highlights = options.highlights;
    this._persistent = options.persistent ?? false;
    this._showCursor = options.showCursor ?? false;
    this._cursorStyle = options.cursorStyle;

    // TextBufferRenderable doesn't read options.focusable (only BoxRenderable does),
    // so we need to read it ourselves.
    if (options.focusable) {
      this._focusable = true;
    }

    // Initialize persistent terminal if enabled
    if (this._persistent && hasPersistentTerminalSupport()) {
      this._persistentTerminal = new PersistentTerminal({
        cols: this._cols,
        rows: this._rows,
      });

      // Feed initial content if provided
      if (
        this._ansi &&
        (typeof this._ansi === "string"
          ? this._ansi.length > 0
          : this._ansi.length > 0)
      ) {
        this._persistentTerminal.feed(this._ansi);
      }
    }

    this._ansiDirty = true;
  }

  /**
   * Returns the total number of lines in the terminal buffer (after limit and trimming)
   */
  get lineCount(): number {
    return this._lineCount;
  }

  get limit(): number | undefined {
    return this._limit;
  }

  set limit(value: number | undefined) {
    if (this._limit !== value) {
      this._limit = value;
      this._ansiDirty = true;
      this.requestRender();
    }
  }

  /**
   * Scroll offset into the terminal scrollback. When undefined, follows the
   * latest output (bottom of scrollback).
   */
  get scrollOffset(): number | undefined {
    return this._scrollOffset;
  }

  set scrollOffset(value: number | undefined) {
    if (this._scrollOffset !== value) {
      this._scrollOffset = value;
      this._ansiDirty = true;
      this.requestRender();
    }
  }

  get trimEnd(): boolean | undefined {
    return this._trimEnd;
  }

  set trimEnd(value: boolean | undefined) {
    if (this._trimEnd !== value) {
      this._trimEnd = value;
      this._ansiDirty = true;
      this.requestRender();
    }
  }

  get highlights(): HighlightRegion[] | undefined {
    return this._highlights;
  }

  set highlights(value: HighlightRegion[] | undefined) {
    this._highlights = value;
    this._ansiDirty = true;
    this.requestRender();
  }

  get showCursor(): boolean {
    return this._showCursor;
  }

  set showCursor(value: boolean) {
    if (this._showCursor !== value) {
      this._showCursor = value;
      this._ansiDirty = true;
      this.requestRender();
    }
  }

  get cursorStyle(): "block" | "underline" | undefined {
    return this._cursorStyle;
  }

  set cursorStyle(value: "block" | "underline" | undefined) {
    if (this._cursorStyle !== value) {
      this._cursorStyle = value;
      this._ansiDirty = true;
      this.requestRender();
    }
  }

  get ansi(): string | Buffer | Uint8Array {
    return this._ansi;
  }

  set ansi(value: string | Buffer | Uint8Array) {
    if (this._ansi !== value) {
      this._ansi = value;

      // In persistent mode, setting ansi replaces all content
      // Note: For streaming, use feed() instead which appends
      if (this._persistentTerminal) {
        this._persistentTerminal.reset();
        if (
          value &&
          (typeof value === "string" ? value.length > 0 : value.length > 0)
        ) {
          this._persistentTerminal.feed(value);
        }
      }

      this._ansiDirty = true;
      this.requestRender();
    }
  }

  get cols(): number {
    return this._cols;
  }

  set cols(value: number) {
    if (this._cols !== value) {
      this._cols = value;
      if (this._persistentTerminal) {
        this._persistentTerminal.resize(value, this._rows);
      }
      this._ansiDirty = true;
      this.requestRender();
    }
  }

  get rows(): number {
    return this._rows;
  }

  set rows(value: number) {
    if (this._rows !== value) {
      this._rows = value;
      if (this._persistentTerminal) {
        this._persistentTerminal.resize(this._cols, value);
      }
      this._ansiDirty = true;
      this.requestRender();
    }
  }

  /** Whether this terminal is in persistent mode */
  get persistent(): boolean {
    return this._persistent;
  }

  /** Persistent mode cannot be changed after construction */
  set persistent(_value: boolean) {
    // No-op: persistent mode is set at construction time and cannot be changed
  }

  /**
   * Feed data to the terminal. Only works in persistent mode.
   * For stateless mode, update the `ansi` property instead.
   *
   * @param data - ANSI data to feed to the terminal
   */
  feed(data: string | Buffer | Uint8Array): void {
    if (!this._persistentTerminal) {
      throw new Error(
        "feed() is only available in persistent mode. Set persistent=true in options.",
      );
    }
    this._persistentTerminal.feed(data);
    this._ansiDirty = true;
    this.requestRender();
  }

  /**
   * Reset the terminal to its initial state. Only works in persistent mode.
   */
  reset(): void {
    if (!this._persistentTerminal) {
      throw new Error(
        "reset() is only available in persistent mode. Set persistent=true in options.",
      );
    }
    this._persistentTerminal.reset();
    this._ansiDirty = true;
    this.requestRender();
  }

  /**
   * Get the current cursor position. Only works in persistent mode.
   * @returns [x, y] cursor position
   */
  getCursor(): [number, number] {
    if (!this._persistentTerminal) {
      throw new Error(
        "getCursor() is only available in persistent mode. Set persistent=true in options.",
      );
    }
    return this._persistentTerminal.getCursor();
  }

  /**
   * Get plain text content of the terminal.
   */
  getText(): string {
    if (this._persistentTerminal) {
      return this._persistentTerminal.getText();
    }
    // For stateless mode, we'd need to parse the ANSI - not implemented yet
    throw new Error(
      "getText() in stateless mode is not implemented. Use persistent=true.",
    );
  }

  /**
   * Clean up resources. Called automatically when the component unmounts.
   */
  override destroy(): void {
    if (this._persistentTerminal) {
      this._persistentTerminal.destroy();
      this._persistentTerminal = null;
    }
    super.destroy();
  }

  protected override onRemove(): void {
    if (this._focused || !this._focusable) {
      this.hideTerminalCursor();
    }
  }

  private hideTerminalCursor(): void {
    this.ctx.setCursorPosition(0, 0, false);
  }

  private renderTerminalCursor(): void {
    if (!this._renderCursor.visible || (this._focusable && !this._focused)) {
      this.hideTerminalCursor();
      return;
    }

    const style = this._cursorStyle ?? this._renderCursor.style;
    this.ctx.setCursorStyle({
      style,
      blinking: false,
    });
    this.ctx.setCursorPosition(
      this.x + this._renderCursor.x + 1,
      this.y + this._renderCursor.y + 1,
      true,
    );
  }

  override focus(): void {
    super.focus();
    this.requestRender();
  }

  override blur(): void {
    super.blur();
    this.hideTerminalCursor();
    this.requestRender();
  }

  protected renderSelf(buffer: any): void {
    if (this._ansiDirty) {
      let data: TerminalData;

      if (this._persistentTerminal) {
        // Compute viewport offset: explicit scroll or follow latest (bottom)
        const lim = this._limit ?? this._rows;
        const total = this._persistentTerminal.getTotalLines();
        const max = Math.max(0, total - lim);
        const offset =
          this._scrollOffset !== undefined
            ? Math.min(this._scrollOffset, max)
            : max;

        data = this._persistentTerminal.getBinary({ offset, limit: lim });
        this._persistentTerminal.markClean();
      } else {
        // Stateless mode - create terminal each time
        data = ptyToJson(this._ansi, {
          cols: this._cols,
          rows: this._rows,
          limit: this._limit,
        });
      }

      // Apply trimEnd: remove empty lines from the end
      if (this._trimEnd) {
        while (data.lines.length > 0) {
          const lastLine = data.lines[data.lines.length - 1];
          const hasText = lastLine.spans.some(
            (span) => span.text.trim().length > 0,
          );
          if (hasText) break;
          data.lines.pop();
        }
      }

      this.textBuffer.setStyledText(
        terminalDataToStyledText(data, this._highlights),
      );
      this.updateTextInfo();
      if (this._showCursor) {
        const cursorY = Math.max(
          0,
          data.totalLines - data.rows + data.cursor[1] - data.offset,
        );
        this._renderCursor.x = data.cursor[0];
        this._renderCursor.y = cursorY;
        this._renderCursor.visible =
          data.cursorVisible && cursorY < data.lines.length;
        // Map Ghostty cursor style names to opentui names
        // "bar" → "line", "default" preserved as "default" (→ \x1b[0 q, native cursor)
        const ts = data.cursorStyle;
        this._renderCursor.style =
          ts === "default"
            ? "default"
            : ts === "bar"
              ? "line"
              : ts === "underline"
                ? "underline"
                : "block";
      } else {
        this._renderCursor.visible = false;
      }

      // Update line count based on actual rendered lines
      const lineInfo = this.textBufferView.logicalLineInfo;
      this._lineCount = getLineStarts(lineInfo).length;

      this._ansiDirty = false;
    }
    super.renderSelf(buffer);
    this.renderTerminalCursor();
  }

  /**
   * Maps an ANSI line number to the corresponding scrollTop position for a parent ScrollBox.
   * Uses the actual rendered Y position from the text buffer's line info, which accounts
   * for text wrapping and actual layout.
   *
   * @param lineNumber - The line number (0-based) in the ANSI output
   * @returns The scrollTop value to pass to ScrollBox.scrollTo()
   *
   * @example
   * ```tsx
   * const scrollPos = terminalBufferRef.current.getScrollPositionForLine(42)
   * scrollBoxRef.current.scrollTo(scrollPos)
   * ```
   */
  getScrollPositionForLine(lineNumber: number): number {
    // Clamp to valid range
    const clampedLine = Math.max(0, Math.min(lineNumber, this._lineCount - 1));

    // Get the line info which contains actual Y offsets for each line
    // This accounts for wrapping and actual text layout
    const lineInfo = this.textBufferView.logicalLineInfo;
    const lineStarts = getLineStarts(lineInfo);

    // If we have line start info, use it; otherwise fall back to simple calculation
    let lineYOffset = clampedLine;
    if (lineStarts && lineStarts.length > clampedLine) {
      lineYOffset = lineStarts[clampedLine];
    }

    // Return the absolute Y position: this renderable's Y + the line's offset within it
    return this.y + lineYOffset;
  }
}

/** @deprecated Use GhosttyTerminalRenderable instead */
export const TerminalBufferRenderable = GhosttyTerminalRenderable;

// =============================================================================
// FrameBuffer-based renderable (Phase 4: bypasses StyledText/TextChunk layer)
// =============================================================================

const rgbCache = new Map<number, RGBA>();

function rgbaFromRGB(r: number, g: number, b: number): RGBA {
  const key = (r << 16) | (g << 8) | b;
  let c = rgbCache.get(key);
  if (c) return c;
  c = RGBA.fromInts(r, g, b);
  rgbCache.set(key, c);
  return c;
}

const TRANSPARENT = RGBA.fromValues(0, 0, 0, 0);

export interface GhosttyFrameBufferOptions extends FrameBufferOptions {
  cols?: number;
  rows?: number;
  showCursor?: boolean;
  cursorStyle?: "block" | "underline";
  highlights?: HighlightRegion[];
}

/**
 * High-performance terminal renderable that writes directly to an OptimizedBuffer
 * via drawText()/setCell(), bypassing the entire StyledText/TextChunk/TextBuffer pipeline.
 *
 * Uses getBinary() to read terminal state as a packed binary buffer, then draws
 * each span directly to the frame buffer.
 */
export class GhosttyFrameBufferRenderable extends FrameBufferRenderable {
  private _terminal: PersistentTerminal;
  private _contentDirty = true;
  private _cols: number;
  private _rows: number;
  private _showCursor = false;
  private _cursorStyle: "block" | "underline" = "block";
  private _highlights?: HighlightRegion[];
  private _limit?: number;
  private _lineCount = 0;
  private _scrollOffset?: number;

  constructor(ctx: RenderContext, options: GhosttyFrameBufferOptions) {
    const cols = options.cols ?? 120;
    const rows = options.rows ?? 40;
    super(ctx, {
      ...options,
      width: cols,
      height: rows,
      respectAlpha: false,
    });

    this._cols = cols;
    this._rows = rows;
    this._showCursor = options.showCursor ?? false;
    this._cursorStyle = options.cursorStyle ?? "block";
    this._highlights = options.highlights;

    this._terminal = new PersistentTerminal({ cols, rows });
  }

  get lineCount(): number {
    return this._lineCount;
  }

  get cols(): number {
    return this._cols;
  }

  set cols(value: number) {
    if (this._cols !== value) {
      this._cols = value;
      this._terminal.resize(value, this._rows);
      this._contentDirty = true;
      this.requestRender();
    }
  }

  get rows(): number {
    return this._rows;
  }

  set rows(value: number) {
    if (this._rows !== value) {
      this._rows = value;
      this._terminal.resize(this._cols, value);
      this._contentDirty = true;
      this.requestRender();
    }
  }

  get limit(): number | undefined {
    return this._limit;
  }

  set limit(value: number | undefined) {
    if (this._limit !== value) {
      this._limit = value;
      this._contentDirty = true;
      this.requestRender();
    }
  }

  get showCursor(): boolean {
    return this._showCursor;
  }

  set showCursor(value: boolean) {
    if (this._showCursor !== value) {
      this._showCursor = value;
      this._contentDirty = true;
      this.requestRender();
    }
  }

  get cursorStyle(): "block" | "underline" {
    return this._cursorStyle;
  }

  set cursorStyle(value: "block" | "underline") {
    if (this._cursorStyle !== value) {
      this._cursorStyle = value;
      this._contentDirty = true;
      this.requestRender();
    }
  }

  get highlights(): HighlightRegion[] | undefined {
    return this._highlights;
  }

  set highlights(value: HighlightRegion[] | undefined) {
    this._highlights = value;
    this._contentDirty = true;
    this.requestRender();
  }

  get scrollOffset(): number | undefined {
    return this._scrollOffset;
  }

  set scrollOffset(value: number | undefined) {
    if (this._scrollOffset !== value) {
      this._scrollOffset = value;
      this._contentDirty = true;
      this.requestRender();
    }
  }

  /** Feed data to the terminal */
  feed(data: string | Buffer | Uint8Array): void {
    this._terminal.feed(data);
    this._contentDirty = true;
    this.requestRender();
  }

  /** Reset the terminal to initial state */
  reset(): void {
    this._terminal.reset();
    this._contentDirty = true;
    this.requestRender();
  }

  /** Get cursor position */
  getCursor(): [number, number] {
    return this._terminal.getCursor();
  }

  /** Get plain text */
  getText(): string {
    return this._terminal.getText();
  }

  /** Get total lines in scrollback */
  getTotalLines(): number {
    return this._terminal.getTotalLines();
  }

  /** The underlying persistent terminal (for advanced scrollback control) */
  get persistentTerminal(): PersistentTerminal {
    return this._terminal;
  }

  protected renderSelf(buffer: OptimizedBuffer): void {
    if (!this._contentDirty) {
      super.renderSelf(buffer);
      return;
    }

    const fb = this.frameBuffer;
    fb.clear(DEFAULT_BG);

    // Get binary data. When scrollOffset is undefined, show latest (bottom of scrollback).
    const lim = this._limit ?? this._rows;
    const total = this._terminal.getTotalLines();
    const maxOffset = Math.max(0, total - lim);
    const offset = this._scrollOffset ?? maxOffset;

    const data = this._terminal.getBinary({
      offset: Math.min(offset, maxOffset),
      limit: lim,
    });
    this._terminal.markClean();

    this._lineCount = data.totalLines;

    // Build highlight lookup
    const hlByLine = new Map<number, HighlightRegion[]>();
    if (this._highlights) {
      for (const hl of this._highlights) {
        const arr = hlByLine.get(hl.line) ?? [];
        arr.push(hl);
        hlByLine.set(hl.line, arr);
      }
    }

    // Compute cursor row in data.lines coordinates
    const cursorDataY = this._showCursor
      ? Math.max(0, data.totalLines - data.rows + data.cursor[1] - data.offset)
      : -1;

    // Render each row
    for (let row = 0; row < data.lines.length; row++) {
      const line = data.lines[row];
      let col = 0;

      for (const span of line.spans) {
        const fg = span.fg ? cachedColor(span.fg) : DEFAULT_FG;
        let bg = span.bg ? cachedColor(span.bg) : TRANSPARENT;

        let fgDraw = fg;
        let bgDraw = bg;

        // Handle inverse
        if (span.flags & StyleFlags.INVERSE) {
          fgDraw = bg.a > 0 ? bg : DEFAULT_BG;
          bgDraw = fg;
        }

        // Map style flags to TextAttributes
        let attrs = 0;
        if (span.flags & StyleFlags.BOLD) attrs |= TextAttributes.BOLD;
        if (span.flags & StyleFlags.ITALIC) attrs |= TextAttributes.ITALIC;
        if (span.flags & StyleFlags.UNDERLINE)
          attrs |= TextAttributes.UNDERLINE;
        if (span.flags & StyleFlags.STRIKETHROUGH)
          attrs |= TextAttributes.STRIKETHROUGH;
        if (span.flags & StyleFlags.FAINT) attrs |= TextAttributes.DIM;

        // Check for highlights on this line
        const lineHl = hlByLine.get(row);
        if (lineHl) {
          // Draw character by character to support partial highlighting
          for (let i = 0; i < span.text.length; i++) {
            const c = col + i;
            let hlBg = bgDraw;
            for (const hl of lineHl) {
              if (c >= hl.start && c < hl.end) {
                hlBg = cachedColor(hl.backgroundColor);
                break;
              }
            }
            fb.setCell(c, row, span.text[i], fgDraw, hlBg, attrs);
          }
        } else {
          // Fast path: draw entire span at once
          fb.drawText(
            span.text,
            col,
            row,
            fgDraw,
            bgDraw.a > 0 ? bgDraw : undefined,
            attrs,
          );
        }

        col += span.width;
      }

      // Draw cursor on this line
      if (row === cursorDataY && this._showCursor && data.cursorVisible) {
        const cx = data.cursor[0];
        // Find the character at cursor position
        let charAtCursor = " ";
        let curCol = 0;
        for (const span of line.spans) {
          if (curCol + span.text.length > cx) {
            charAtCursor = span.text[cx - curCol] ?? " ";
            break;
          }
          curCol += span.text.length;
        }

        if (this._cursorStyle === "block") {
          fb.setCell(cx, row, charAtCursor, DEFAULT_BG, DEFAULT_FG, 0);
        } else {
          fb.setCell(
            cx,
            row,
            charAtCursor,
            DEFAULT_FG,
            TRANSPARENT,
            TextAttributes.UNDERLINE,
          );
        }
      }
    }

    this._contentDirty = false;
    super.renderSelf(buffer);
  }

  override destroy(): void {
    this._terminal.destroy();
    super.destroy();
  }
}
