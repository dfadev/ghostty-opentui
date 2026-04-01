import {
  FrameBufferRenderable,
  type FrameBufferOptions,
  RGBA,
  type RenderContext,
  type OptimizedBuffer,
} from "@opentui/core"
import {
  PersistentTerminal,
  hasPersistentTerminalSupport,
  StyleFlags,
} from "./ffi.js"

export { hasPersistentTerminalSupport, PersistentTerminal }

const colorCache = new Map<string, RGBA>()

function cachedColor(hex: string): RGBA {
  let c = colorCache.get(hex)
  if (c) return c
  c = RGBA.fromHex(hex)
  colorCache.set(hex, c)
  return c
}

const DEFAULT_FG = cachedColor("#d4d4d4")
const DEFAULT_BG = cachedColor("#1e1e1e")

/**
 * Defines a region to highlight in the terminal output.
 */
export interface HighlightRegion {
  line: number
  start: number
  end: number
  replaceWithX?: boolean
  backgroundColor: string
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
}

const rgbCache = new Map<number, RGBA>()

function rgbaFromRGB(r: number, g: number, b: number): RGBA {
  const key = (r << 16) | (g << 8) | b
  let c = rgbCache.get(key)
  if (c) return c
  c = RGBA.fromInts(r, g, b)
  rgbCache.set(key, c)
  return c
}

const TRANSPARENT = RGBA.fromValues(0, 0, 0, 0)

export interface GhosttyFrameBufferOptions extends FrameBufferOptions {
  cols?: number
  rows?: number
  showCursor?: boolean
  cursorStyle?: "block" | "underline"
  highlights?: HighlightRegion[]
  persistent?: boolean
  /** Override the default background color (default: #1e1e1e) */
  defaultBg?: string
}

/**
 * High-performance terminal renderable that reads raw binary cell data
 * and writes directly to an OptimizedBuffer via drawText()/setCell().
 * No intermediate JS objects, no hex color strings, no StyledText pipeline.
 */
export class GhosttyFrameBufferRenderable extends FrameBufferRenderable {
  private _terminal: PersistentTerminal
  private _contentDirty = true
  private _cols: number
  private _rows: number
  private _showCursor = false
  private _cursorStyle: "block" | "underline" = "block"
  private _highlights?: HighlightRegion[]
  private _limit?: number
  private _lineCount = 0
  private _scrollOffset?: number
  private _lastCursorX = 0
  private _lastCursorDataY = -1
  private _lastCursorVisible = false
  private _lastCursorStyleByte = 0
  private _lastRenderX = -1
  private _lastRenderY = -1
  private _defaultBg: RGBA
  private _respectAlpha: boolean

  constructor(ctx: RenderContext, options: GhosttyFrameBufferOptions) {
    const cols = options.cols ?? 120
    const rows = options.rows ?? 40
    super(ctx, {
      ...options,
      width: cols,
      height: rows,
      respectAlpha: options.respectAlpha ?? false,
    })

    this._cols = cols
    this._rows = rows
    this._showCursor = options.showCursor ?? false
    this._cursorStyle = options.cursorStyle ?? "block"
    this._highlights = options.highlights
    this._defaultBg = options.defaultBg ? cachedColor(options.defaultBg) : DEFAULT_BG
    this._respectAlpha = options.respectAlpha ?? false

    this._terminal = new PersistentTerminal({ cols, rows })
  }

  get lineCount(): number {
    return this._lineCount
  }

  get cols(): number {
    return this._cols
  }

  set cols(value: number) {
    if (this._cols !== value) {
      this._cols = value
      this._terminal.resize(value, this._rows)
      this.yogaNode.setWidth(value)
      this._contentDirty = true
      this.requestRender()
    }
  }

  get rows(): number {
    return this._rows
  }

  set rows(value: number) {
    if (this._rows !== value) {
      this._rows = value
      this._terminal.resize(this._cols, value)
      this.yogaNode.setHeight(value)
      this._contentDirty = true
      this.requestRender()
    }
  }

  get limit(): number | undefined {
    return this._limit
  }

  set limit(value: number | undefined) {
    if (this._limit !== value) {
      this._limit = value
      this._contentDirty = true
      this.requestRender()
    }
  }

  get showCursor(): boolean {
    return this._showCursor
  }

  set showCursor(value: boolean) {
    if (this._showCursor !== value) {
      this._showCursor = value
      this._contentDirty = true
      this.requestRender()
    }
  }

  get cursorStyle(): "block" | "underline" {
    return this._cursorStyle
  }

  set cursorStyle(value: "block" | "underline") {
    if (this._cursorStyle !== value) {
      this._cursorStyle = value
      this._contentDirty = true
      this.requestRender()
    }
  }

  get highlights(): HighlightRegion[] | undefined {
    return this._highlights
  }

  set highlights(value: HighlightRegion[] | undefined) {
    this._highlights = value
    this._contentDirty = true
    this.requestRender()
  }

  set defaultBg(value: string) {
    const c = cachedColor(value)
    if (this._defaultBg !== c) {
      this._defaultBg = c
      this._contentDirty = true
      this.requestRender()
    }
  }

  get scrollOffset(): number | undefined {
    return this._scrollOffset
  }

  set scrollOffset(value: number | undefined) {
    if (this._scrollOffset !== value) {
      this._scrollOffset = value
      this._contentDirty = true
      this.requestRender()
    }
  }

  feed(data: string | Buffer | Uint8Array): void {
    this._terminal.feed(data)
    this._contentDirty = true
    this.requestRender()
  }

  reset(): void {
    this._terminal.reset()
    this._contentDirty = true
    this.requestRender()
  }

  getCursor(): [number, number] {
    return this._terminal.getCursor()
  }

  getText(): string {
    return this._terminal.getText()
  }

  getTotalLines(): number {
    return this._terminal.getTotalLines()
  }

  get persistentTerminal(): PersistentTerminal {
    return this._terminal
  }

  private _setCursor(): void {
    if (this._showCursor && this._lastCursorVisible && this._lastCursorDataY >= 0 && this._lastCursorDataY < this._rows) {
      const style = this._lastCursorStyleByte === 2 ? "line"
        : this._lastCursorStyleByte === 3 ? "underline"
        : this._lastCursorStyleByte === 1 ? "block"
        : "line"
      this.ctx.setCursorStyle({ style, blinking: false })
      this.ctx.setCursorPosition(this.x + this._lastCursorX + 1, this.y + this._lastCursorDataY + 1, true)
    } else {
      this.ctx.setCursorPosition(0, 0, false)
    }
  }

  protected renderSelf(buffer: OptimizedBuffer): void {
    if (!this._contentDirty) {
      if (this.x !== this._lastRenderX || this.y !== this._lastRenderY) {
        this._lastRenderX = this.x
        this._lastRenderY = this.y
        this._setCursor()
      }
      super.renderSelf(buffer)
      return
    }

    const fb = this.frameBuffer
    fb.clear(this._respectAlpha ? TRANSPARENT : this._defaultBg)

    const lim = this._limit ?? this._rows
    const buf = this._terminal.getRawCellsBatched(
      this._scrollOffset ?? -1,
      lim,
    )

    const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
    const decoder = new TextDecoder()

    let pos = 0
    const hdrRows = view.getUint16(2, true)
    const cursorX = view.getUint16(4, true)
    const cursorRawY = view.getUint16(6, true)
    const cursorVisible = buf[8] === 1
    const cursorStyleByte = buf[9]
    const dataOffset = view.getUint32(12, true)
    const totalLines = view.getUint32(16, true)
    const numRows = view.getUint16(20, true)
    pos = 24

    this._lineCount = totalLines

    const hlByLine = this._highlights ? new Map<number, HighlightRegion[]>() : null
    if (this._highlights && hlByLine) {
      for (const hl of this._highlights) {
        const arr = hlByLine.get(hl.line) ?? []
        arr.push(hl)
        hlByLine.set(hl.line, arr)
      }
    }

    const cursorDataY = this._showCursor
      ? Math.max(0, totalLines - hdrRows + cursorRawY - dataOffset)
      : -1

    for (let row = 0; row < numRows; row++) {
      const numSpans = view.getUint16(pos, true)
      pos += 2
      let col = 0
      const lineHl = hlByLine?.get(row)

      for (let s = 0; s < numSpans; s++) {
        const width = view.getUint16(pos, true)
        pos += 2
        const fgR = buf[pos++]
        const fgG = buf[pos++]
        const fgB = buf[pos++]
        const fgP = buf[pos++]
        const bgR = buf[pos++]
        const bgG = buf[pos++]
        const bgB = buf[pos++]
        const bgP = buf[pos++]
        const flags = buf[pos++]
        pos++ // pad
        const textLen = view.getUint16(pos, true)
        pos += 2
        const text = decoder.decode(buf.subarray(pos, pos + textLen))
        pos += textLen

        const fg = fgP ? rgbaFromRGB(fgR, fgG, fgB) : DEFAULT_FG
        const bg = bgP ? rgbaFromRGB(bgR, bgG, bgB) : TRANSPARENT

        let fgDraw = fg
        let bgDraw = bg

        if (flags & StyleFlags.INVERSE) {
          fgDraw = bg.a > 0 ? bg : this._defaultBg
          bgDraw = fg
        }

        let attrs = 0
        if (flags & StyleFlags.BOLD) attrs |= TextAttributes.BOLD
        if (flags & StyleFlags.ITALIC) attrs |= TextAttributes.ITALIC
        if (flags & StyleFlags.UNDERLINE) attrs |= TextAttributes.UNDERLINE
        if (flags & StyleFlags.STRIKETHROUGH) attrs |= TextAttributes.STRIKETHROUGH
        if (flags & StyleFlags.FAINT) attrs |= TextAttributes.DIM

        if (lineHl) {
          for (let i = 0; i < text.length; i++) {
            const c = col + i
            let hlBg = bgDraw
            for (const hl of lineHl) {
              if (c >= hl.start && c < hl.end) {
                hlBg = cachedColor(hl.backgroundColor)
                break
              }
            }
            fb.setCell(c, row, text[i], fgDraw, hlBg, attrs)
          }
        } else {
          fb.drawText(text, col, row, fgDraw, bgDraw.a > 0 ? bgDraw : undefined, attrs)
        }

        col += width
      }
    }

    this._lastCursorX = cursorX
    this._lastCursorDataY = cursorDataY
    this._lastCursorVisible = cursorVisible
    this._lastCursorStyleByte = cursorStyleByte

    this._setCursor()

    this._contentDirty = false
    super.renderSelf(buffer)
  }

  override destroy(): void {
    this._terminal.destroy()
    super.destroy()
  }
}
