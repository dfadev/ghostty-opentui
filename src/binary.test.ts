import { test, expect } from "bun:test"
import { PersistentTerminal, hasPersistentTerminalSupport } from "./ffi.js"

test("getBinary matches getJson for plain text", () => {
  if (!hasPersistentTerminalSupport()) return

  const term = new PersistentTerminal({ cols: 80, rows: 24 })
  term.feed("Hello World")

  const json = term.getJson()
  const bin = term.getBinary()

  expect(bin.cols).toBe(json.cols)
  expect(bin.rows).toBe(json.rows)
  expect(bin.cursor).toEqual(json.cursor)
  expect(bin.cursorVisible).toBe(json.cursorVisible)
  expect(bin.offset).toBe(json.offset)
  expect(bin.totalLines).toBe(json.totalLines)
  expect(bin.lines.length).toBe(json.lines.length)

  // First line should match
  expect(bin.lines[0].spans.length).toBe(json.lines[0].spans.length)
  expect(bin.lines[0].spans[0].text).toBe(json.lines[0].spans[0].text)
  expect(bin.lines[0].spans[0].width).toBe(json.lines[0].spans[0].width)

  term.destroy()
})

test("getBinary matches getJson with ANSI colors", () => {
  if (!hasPersistentTerminalSupport()) return

  const term = new PersistentTerminal({ cols: 80, rows: 24 })
  term.feed("\x1b[31mRed\x1b[0m \x1b[32mGreen\x1b[0m")

  const json = term.getJson()
  const bin = term.getBinary()

  for (let i = 0; i < json.lines.length; i++) {
    expect(bin.lines[i].spans.length).toBe(json.lines[i].spans.length)
    for (let j = 0; j < json.lines[i].spans.length; j++) {
      expect(bin.lines[i].spans[j].text).toBe(json.lines[i].spans[j].text)
      expect(bin.lines[i].spans[j].fg).toBe(json.lines[i].spans[j].fg)
      expect(bin.lines[i].spans[j].bg).toBe(json.lines[i].spans[j].bg)
      expect(bin.lines[i].spans[j].flags).toBe(json.lines[i].spans[j].flags)
      expect(bin.lines[i].spans[j].width).toBe(json.lines[i].spans[j].width)
    }
  }

  term.destroy()
})

test("getBinary preserves high-byte RGB values", () => {
  if (!hasPersistentTerminalSupport()) return

  const term = new PersistentTerminal({ cols: 80, rows: 24 })
  // RGB(200, 128, 255) — tests bytes that would corrupt via UTF-8 string path
  term.feed("\x1b[38;2;200;128;255mHigh\x1b[0m")

  const json = term.getJson()
  const bin = term.getBinary()

  expect(bin.lines[0].spans[0].text).toBe("High")
  expect(bin.lines[0].spans[0].fg).toBe(json.lines[0].spans[0].fg)

  term.destroy()
})

test("getBinary with offset and limit", () => {
  if (!hasPersistentTerminalSupport()) return

  const term = new PersistentTerminal({ cols: 80, rows: 24 })
  term.feed("Line0\nLine1\nLine2\nLine3\n")

  const json = term.getJson({ offset: 1, limit: 2 })
  const bin = term.getBinary({ offset: 1, limit: 2 })

  expect(bin.offset).toBe(json.offset)
  expect(bin.lines.length).toBe(json.lines.length)

  for (let i = 0; i < json.lines.length; i++) {
    for (let j = 0; j < json.lines[i].spans.length; j++) {
      expect(bin.lines[i].spans[j].text).toBe(json.lines[i].spans[j].text)
    }
  }

  term.destroy()
})
