/**
 * A minimal, dependency-free .xlsx (Office Open XML) writer for one-sheet
 * exports. Pure: builds the file bytes in memory, no DOM and no network.
 *
 * Supports exactly what the exports need: a bold, frozen header row, column
 * widths, text cells (wrapped when long), numbers, and real Excel date/time
 * cells (serial numbers with a date format). The package is stored without
 * compression (ZIP "stored" entries), which every spreadsheet program reads.
 */

export type XlsxCell =
  | { kind: "text"; value: string }
  | { kind: "number"; value: number }
  /** An Excel serial date/time (days since 1899-12-30, wall-clock time) with a display format. */
  | { kind: "date"; serial: number; format: "date" | "time" | "datetime" }
  | { kind: "empty" };

export type XlsxColumn = { header: string; width: number; wrap?: boolean };

/** Excel's hard limit on characters in one cell. */
export const XLSX_MAX_CELL_CHARS = 32767;

const xmlEscape = (s: string): string =>
  s
    // Characters XML 1.0 does not allow at all.
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

/** Column letters for a zero-based index: 0 -> A, 25 -> Z, 26 -> AA. */
export function columnName(index: number): string {
  let name = "";
  let n = index + 1;
  while (n > 0) {
    const r = (n - 1) % 26;
    name = String.fromCharCode(65 + r) + name;
    n = Math.floor((n - 1) / 26);
  }
  return name;
}

// Style ids in styles.xml (cellXfs order below).
const STYLE = { text: 0, header: 1, wrap: 2, date: 3, time: 4, datetime: 5 } as const;

function cellXml(ref: string, cell: XlsxCell, wrap: boolean): string {
  switch (cell.kind) {
    case "empty":
      return "";
    case "number":
      return Number.isFinite(cell.value) ? `<c r="${ref}"><v>${cell.value}</v></c>` : "";
    case "date":
      return `<c r="${ref}" s="${STYLE[cell.format]}"><v>${cell.serial}</v></c>`;
    case "text": {
      const text = cell.value.length > XLSX_MAX_CELL_CHARS ? cell.value.slice(0, XLSX_MAX_CELL_CHARS) : cell.value;
      const space = /^\s|\s$|\n/.test(text) ? ' xml:space="preserve"' : "";
      return `<c r="${ref}" t="inlineStr"${wrap ? ` s="${STYLE.wrap}"` : ""}><is><t${space}>${xmlEscape(text)}</t></is></c>`;
    }
  }
}

function sheetXml(columns: XlsxColumn[], rows: XlsxCell[][]): string {
  const lastCol = columnName(Math.max(columns.length - 1, 0));
  const lastRow = rows.length + 1;
  const cols = columns
    .map((c, i) => `<col min="${i + 1}" max="${i + 1}" width="${c.width}" customWidth="1"/>`)
    .join("");
  const header =
    `<row r="1">` +
    columns.map((c, i) => `<c r="${columnName(i)}1" t="inlineStr" s="${STYLE.header}"><is><t>${xmlEscape(c.header)}</t></is></c>`).join("") +
    `</row>`;
  const body = rows
    .map((row, r) => {
      const n = r + 2;
      return `<row r="${n}">` + row.map((cell, i) => cellXml(`${columnName(i)}${n}`, cell, Boolean(columns[i]?.wrap))).join("") + `</row>`;
    })
    .join("");
  return (
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">` +
    `<dimension ref="A1:${lastCol}${lastRow}"/>` +
    // Frozen header row.
    `<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>` +
    `<selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>` +
    `<sheetFormatPr defaultRowHeight="15"/>` +
    `<cols>${cols}</cols>` +
    `<sheetData>${header}${body}</sheetData>` +
    `<autoFilter ref="A1:${lastCol}${lastRow}"/>` +
    `</worksheet>`
  );
}

const STYLES_XML =
  `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
  `<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">` +
  `<numFmts count="3">` +
  `<numFmt numFmtId="164" formatCode="yyyy-mm-dd"/>` +
  `<numFmt numFmtId="165" formatCode="hh:mm:ss"/>` +
  `<numFmt numFmtId="166" formatCode="yyyy-mm-dd hh:mm:ss"/>` +
  `</numFmts>` +
  `<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font></fonts>` +
  `<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>` +
  `<fill><patternFill patternType="solid"><fgColor rgb="FF0F172A"/><bgColor indexed="64"/></patternFill></fill></fills>` +
  `<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>` +
  `<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>` +
  `<cellXfs count="6">` +
  `<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"><alignment vertical="top"/></xf>` +
  `<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"><alignment vertical="center"/></xf>` +
  `<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf>` +
  `<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"><alignment vertical="top"/></xf>` +
  `<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"><alignment vertical="top"/></xf>` +
  `<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"><alignment vertical="top"/></xf>` +
  `</cellXfs>` +
  `<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>` +
  `</styleSheet>`;

// ---------------------------------------------------------------------------
// ZIP (stored entries, no compression)
// ---------------------------------------------------------------------------

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function zipStored(files: { name: string; data: Uint8Array }[]): Uint8Array {
  const enc = new TextEncoder();
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;
  // Fixed DOS timestamp (1980-01-01 00:00): the content, not the zip entry time, carries the dates.
  const dosTime = 0, dosDate = (0 << 9) | (1 << 5) | 1;
  for (const file of files) {
    const name = enc.encode(file.name);
    const crc = crc32(file.data);
    const size = file.data.length;
    const local = new Uint8Array(30 + name.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(4, 20, true);
    lv.setUint16(6, 0x0800, true); // UTF-8 names
    lv.setUint16(8, 0, true); // stored
    lv.setUint16(10, dosTime, true);
    lv.setUint16(12, dosDate, true);
    lv.setUint32(14, crc, true);
    lv.setUint32(18, size, true);
    lv.setUint32(22, size, true);
    lv.setUint16(26, name.length, true);
    lv.setUint16(28, 0, true);
    local.set(name, 30);
    const central = new Uint8Array(46 + name.length);
    const cv = new DataView(central.buffer);
    cv.setUint32(0, 0x02014b50, true);
    cv.setUint16(4, 20, true);
    cv.setUint16(6, 20, true);
    cv.setUint16(8, 0x0800, true);
    cv.setUint16(10, 0, true);
    cv.setUint16(12, dosTime, true);
    cv.setUint16(14, dosDate, true);
    cv.setUint32(16, crc, true);
    cv.setUint32(20, size, true);
    cv.setUint32(24, size, true);
    cv.setUint16(28, name.length, true);
    cv.setUint32(42, offset, true);
    central.set(name, 46);
    locals.push(local, file.data);
    centrals.push(central);
    offset += local.length + size;
  }
  const centralSize = centrals.reduce((s, c) => s + c.length, 0);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, files.length, true);
  ev.setUint16(10, files.length, true);
  ev.setUint32(12, centralSize, true);
  ev.setUint32(16, offset, true);
  const out = new Uint8Array(offset + centralSize + end.length);
  let p = 0;
  for (const part of [...locals, ...centrals, end]) {
    out.set(part, p);
    p += part.length;
  }
  return out;
}

export type XlsxSheet = { name: string; columns: XlsxColumn[]; rows: XlsxCell[][] };

/** Builds a one-sheet .xlsx workbook. Returns the file bytes. */
export function buildXlsx(sheetName: string, columns: XlsxColumn[], rows: XlsxCell[][]): Uint8Array {
  return buildXlsxWorkbook([{ name: sheetName, columns, rows }]);
}

/**
 * Builds a workbook with one or more sheets. With a single sheet the bytes are
 * identical to what buildXlsx() always produced (Phase 12 audit export).
 */
export function buildXlsxWorkbook(sheets: XlsxSheet[]): Uint8Array {
  if (sheets.length === 0) throw new Error("A workbook needs at least one sheet");
  const enc = new TextEncoder();
  const used = new Set<string>();
  const names = sheets.map((sh, i) => {
    const base = sh.name.replace(/[\\/?*[\]:]/g, " ").slice(0, 31) || `Sheet${i + 1}`;
    let name = base, n = 2;
    while (used.has(name.toLowerCase())) name = `${base.slice(0, 28)} ${n++}`;
    used.add(name.toLowerCase());
    return xmlEscape(name);
  });
  const files: { name: string; text: string }[] = [
    {
      name: "[Content_Types].xml",
      text:
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
        `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
        `<Default Extension="xml" ContentType="application/xml"/>` +
        `<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
        sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("") +
        `<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>` +
        `</Types>`,
    },
    {
      name: "_rels/.rels",
      text:
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
        `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>` +
        `</Relationships>`,
    },
    {
      name: "xl/workbook.xml",
      text:
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
        `<sheets>` + names.map((n, i) => `<sheet name="${n}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("") + `</sheets>` +
        `<definedNames>` +
        sheets.map((sh, i) => `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">'${names[i].replace(/'/g, "''")}'!$A$1:$${columnName(Math.max(sh.columns.length - 1, 0))}$${sh.rows.length + 1}</definedName>`).join("") +
        `</definedNames>` +
        `</workbook>`,
    },
    {
      name: "xl/_rels/workbook.xml.rels",
      text:
        `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
        `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
        sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join("") +
        `<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>` +
        `</Relationships>`,
    },
    { name: "xl/styles.xml", text: STYLES_XML },
    ...sheets.map((sh, i) => ({ name: `xl/worksheets/sheet${i + 1}.xml`, text: sheetXml(sh.columns, sh.rows) })),
  ];
  return zipStored(files.map((f) => ({ name: f.name, data: enc.encode(f.text) })));
}

/** Excel serial for a wall-clock time given as milliseconds since 1970-01-01 in that wall clock. */
export function excelSerialFromWallClockMs(wallClockMs: number): number {
  return wallClockMs / 86_400_000 + 25_569;
}
