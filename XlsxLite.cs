using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Xml.Linq;

namespace CMSMailbox
{
    // Minimal .xlsx writer/reader (2026-11-18, Dynamic Report bulk update) on System.IO.Compression,
    // so the mailbox needs no Excel library or license (CMSNEO uses GemBox).
    //   Write: one sheet, row 1 = headers, every cell an inline string styled as Text (numFmt 49),
    //          so Excel keeps typed values as text (no date/number reformatting on re-save).
    //   Read:  the first worksheet, row 1 = headers; shared, inline and plain strings, and numbers
    //          (as invariant strings). Formulas give their cached value.
    public static class XlsxLite
    {
        private static readonly XNamespace S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
        private static readonly XNamespace R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        private static readonly XNamespace PR = "http://schemas.openxmlformats.org/package/2006/relationships";

        public static byte[] Write(IList<string> headers, IEnumerable<IList<string>> rows, string sheetName = "Report")
        {
            using var ms = new MemoryStream();
            using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, true))
            {
                void Add(string path, string xml)
                {
                    var e = zip.CreateEntry(path, CompressionLevel.Optimal);
                    using var w = new StreamWriter(e.Open(), new UTF8Encoding(false));
                    w.Write(xml);
                }

                Add("[Content_Types].xml",
                    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
                    "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" +
                    "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" +
                    "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" +
                    "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>" +
                    "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" +
                    "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>" +
                    "</Types>");
                Add("_rels/.rels",
                    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
                    "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
                    "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>" +
                    "</Relationships>");
                Add("xl/workbook.xml",
                    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
                    "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">" +
                    "<sheets><sheet name=\"" + Esc(SafeSheetName(sheetName)) + "\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>");
                Add("xl/_rels/workbook.xml.rels",
                    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
                    "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" +
                    "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>" +
                    "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>" +
                    "</Relationships>");
                // Style 1 = Text (numFmtId 49), bold font for the header row = style 2.
                Add("xl/styles.xml",
                    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" +
                    "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">" +
                    "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>" +
                    "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>" +
                    "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>" +
                    "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>" +
                    "<cellXfs count=\"3\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>" +
                    "<xf numFmtId=\"49\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" +
                    "<xf numFmtId=\"49\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\"/></cellXfs>" +
                    "</styleSheet>");

                var sb = new StringBuilder();
                sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>");
                sb.Append("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">");
                // Whole columns styled as Text too, so cells typed into later stay text.
                sb.Append("<cols><col min=\"1\" max=\"" + Math.Max(1, headers.Count) + "\" width=\"22\" style=\"1\" customWidth=\"1\"/></cols><sheetData>");
                int r = 1;
                void Row(IList<string> vals, int style)
                {
                    sb.Append("<row r=\"").Append(r).Append("\">");
                    for (int c = 0; c < vals.Count; c++)
                        sb.Append("<c r=\"").Append(ColName(c)).Append(r).Append("\" t=\"inlineStr\" s=\"").Append(style).Append("\"><is><t xml:space=\"preserve\">")
                          .Append(Esc(vals[c] ?? "")).Append("</t></is></c>");
                    sb.Append("</row>");
                    r++;
                }
                Row(headers, 2);
                foreach (var row in rows) Row(row, 1);
                sb.Append("</sheetData></worksheet>");
                Add("xl/worksheets/sheet1.xml", sb.ToString());
            }
            return ms.ToArray();
        }

        // Headers (row 1) and the rows under them, each row as header -> value ("" for empty cells).
        // Fully empty rows are left out.
        public static (List<string> Headers, List<Dictionary<string, string>> Rows) Read(byte[] bytes)
        {
            using var ms = new MemoryStream(bytes);
            using var zip = new ZipArchive(ms, ZipArchiveMode.Read);

            XDocument Load(string path)
            {
                var e = zip.GetEntry(path);
                if (e == null) return null;
                using var s = e.Open();
                return XDocument.Load(s);
            }

            var shared = new List<string>();
            var sst = Load("xl/sharedStrings.xml");
            if (sst != null)
                foreach (var si in sst.Root.Elements(S + "si"))
                    shared.Add(string.Concat(si.Descendants(S + "t").Select(t => t.Value)));

            // First sheet in workbook order (not necessarily sheet1.xml).
            string sheetPath = "xl/worksheets/sheet1.xml";
            var wb = Load("xl/workbook.xml");
            var rels = Load("xl/_rels/workbook.xml.rels");
            var first = wb?.Root.Element(S + "sheets")?.Elements(S + "sheet").FirstOrDefault();
            var rid = first?.Attribute(R + "id")?.Value;
            var target = rels?.Root.Elements(PR + "Relationship").FirstOrDefault(x => x.Attribute("Id")?.Value == rid)?.Attribute("Target")?.Value;
            if (!string.IsNullOrEmpty(target))
                sheetPath = target.StartsWith("/") ? target.TrimStart('/') : "xl/" + target.Replace("\\", "/");

            var sheet = Load(sheetPath) ?? throw new InvalidDataException("no worksheet");
            var grid = new List<Dictionary<int, string>>();
            foreach (var row in sheet.Root.Element(S + "sheetData")?.Elements(S + "row") ?? Enumerable.Empty<XElement>())
            {
                var cells = new Dictionary<int, string>();
                int next = 0;
                foreach (var c in row.Elements(S + "c"))
                {
                    var refAttr = c.Attribute("r")?.Value;
                    int col = refAttr != null ? ColIndex(refAttr) : next;
                    next = col + 1;
                    string type = c.Attribute("t")?.Value;
                    string v = c.Element(S + "v")?.Value;
                    string val;
                    if (type == "s") val = int.TryParse(v, out var i) && i >= 0 && i < shared.Count ? shared[i] : "";
                    else if (type == "inlineStr") val = string.Concat(c.Element(S + "is")?.Descendants(S + "t").Select(t => t.Value) ?? Enumerable.Empty<string>());
                    else if (type == "b") val = v == "1" ? "TRUE" : "FALSE";
                    else if (v != null && (type == null || type == "n") && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var d))
                        val = d.ToString(CultureInfo.InvariantCulture);
                    else val = v ?? "";
                    cells[col] = val;
                }
                grid.Add(cells);
            }

            var headers = new List<string>();
            if (grid.Count == 0) return (headers, new List<Dictionary<string, string>>());
            int width = grid[0].Keys.DefaultIfEmpty(-1).Max() + 1;
            for (int c = 0; c < width; c++) headers.Add(grid[0].TryGetValue(c, out var h) ? h.Trim() : "");

            var rows = new List<Dictionary<string, string>>();
            foreach (var cells in grid.Skip(1))
            {
                if (cells.Values.All(string.IsNullOrWhiteSpace)) continue;
                var o = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int c = 0; c < headers.Count; c++)
                    if (headers[c] != "" && !o.ContainsKey(headers[c])) o[headers[c]] = cells.TryGetValue(c, out var v) ? v : "";
                rows.Add(o);
            }
            return (headers, rows);
        }

        private static string ColName(int index)
        {
            var s = "";
            for (int n = index + 1; n > 0; n = (n - 1) / 26) s = (char)('A' + (n - 1) % 26) + s;
            return s;
        }

        private static int ColIndex(string cellRef)
        {
            int n = 0;
            foreach (char ch in cellRef)
            {
                if (ch >= 'A' && ch <= 'Z') n = n * 26 + (ch - 'A' + 1);
                else if (ch >= 'a' && ch <= 'z') n = n * 26 + (ch - 'a' + 1);
                else break;
            }
            return n - 1;
        }

        private static string SafeSheetName(string name)
        {
            var s = new string((name ?? "Report").Where(ch => "[]:*?/\\".IndexOf(ch) < 0).ToArray()).Trim();
            if (s == "") s = "Report";
            return s.Length > 31 ? s.Substring(0, 31) : s;
        }

        private static string Esc(string s)
        {
            var sb = new StringBuilder(s.Length);
            foreach (char ch in s)
            {
                if (ch == '&') sb.Append("&amp;");
                else if (ch == '<') sb.Append("&lt;");
                else if (ch == '>') sb.Append("&gt;");
                else if (ch == '"') sb.Append("&quot;");
                else if (ch < 0x20 && ch != '\t' && ch != '\n' && ch != '\r') continue; // not allowed in XML
                else sb.Append(ch);
            }
            return sb.ToString();
        }
    }
}
