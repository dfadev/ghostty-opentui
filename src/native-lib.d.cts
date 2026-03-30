export interface NativeModule {
  // Stateless functions (create terminal each call)
  ptyToJson(
    input: string,
    cols: number,
    rows: number,
    offset: number,
    limit: number,
  ): string
  ptyToText(input: string, cols: number, rows: number): string
  ptyToHtml(input: string, cols: number, rows: number): string

  // Persistent terminal management functions
  createTerminal(id: number, cols: number, rows: number): void
  destroyTerminal(id: number): void
  feedTerminal(id: number, data: string): void
  feedTerminalBuffer(id: number, data: Buffer | Uint8Array): void
  resizeTerminal(id: number, cols: number, rows: number): void
  resetTerminal(id: number): void
  getTerminalJson(id: number, offset: number, limit: number): string
  getTerminalText(id: number): string
  getTerminalCursor(id: number): string
  getTerminalTotalLines(id: number): number
  isTerminalReady(id: number): boolean
  getTerminalCells(id: number, offset: number, limit: number): Buffer
  getTerminalCellsBatched(id: number, scrollOffset: number, limit: number): Buffer
  isTerminalDirty(id: number): boolean
  markTerminalClean(id: number): void
}

export const native: NativeModule | null
