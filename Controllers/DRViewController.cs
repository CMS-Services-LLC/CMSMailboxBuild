using System;
using System.Collections.Generic;
using System.Data;
using System.IO;
using System.Linq;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace CMSMailbox.Controllers
{
    // Dynamic Report viewer (sql/010): a completed Dynamic Report task's report, or the
    // view-only copy a reply carries. Rows can be edited (by the row's own company),
    // and notes and attachments added, using CMSNEO's own procs.
    //
    // Those record procs don't check access themselves (CMSNEO's checks are in its
    // page flow, or commented out), so every request here does it first:
    //   - MBX_GetDRItemReport: the caller is a recipient or the author of the message
    //     this item is on, and the item is a completed report.
    //   - MBX_GetDRRowAccess (for anything about one row): the row belongs to that
    //     report and passes CMSNEO's own report-visibility rule (AccessTreeDown);
    //     also says whether it's the caller's own company's row (IsMine).
    // Value edits additionally require IsMine (NEO_DynamicRecordUpdate re-checks
    // this). Deleting a note or attachment is limited to the person who added it.
    //
    // Note: CMSNEO keys a report row's notes / history by the row id NEGATED (fid =
    // -id), and its docs procs take either sign — the routes here take the positive id.
    public class DRViewController : MailboxControllerBase
    {
        [HttpGet("item/{messageItemId:int}/report")]
        public IActionResult Report(int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049

            string reportId = ReportFor(messageItemId, uid);
            if (reportId == null) return NotFound();

            // sql/047 (2026-11-18, first numbered 046): not NEO_GetDynamicReportsALL2 any more. Since drt_001 that proc
            // only returns rows to people with the report's type, and with no rows its pivot throws,
            // so Action Request recipients (usually no Dynamic Reports access) got "couldn't be
            // loaded". MBX_GetDRItemReportRows re-checks this item and keeps the AccessTreeDown rule.
            var dat = DB.GetDB("exec MBX_GetDRItemReportRows @uid, @messageItemId", uid,
                new JObject { ["messageItemId"] = messageItemId }.ToString());
            if (dat.Columns.Contains("err"))
            {
                LogAccess(messageItemId, uid, "Denied", "DR report: MBX_GetDRItemReportRows failed");
                return NotFound();
            }

            LogAccess(messageItemId, uid, "Served", "DR report (" + dat.Rows.Count + " rows)");
            return Content(JsonConvert.SerializeObject(NameReportColumns(dat)), "application/json");
        }

        // ---- Bulk update (2026-11-18, like CMSNEO's Update Report Data) ---------------------------
        // Export: your own company's rows as .xlsx (RowID + the report's columns, all Text cells).
        // Upload: the edited file. Every row is matched by RowID to an active row of THIS report,
        // must pass RowAccess with IsMine (the same rule as Submit Changes), and only rows whose
        // values changed are sent to NEO_DynamicRecordUpdate (which re-checks the company and
        // keeps a history copy). Rows without a RowID are added as new records (your company's
        // report only, 2026-11-18). Nothing is deleted: rows left out of the file are kept.
        // (CMSNEO's NEO_UpdateDynamicReports_v4 is deliberately NOT used: it deactivates every row
        // of the report that isn't in the upload, other companies' rows included.)
        private const int BulkMaxRows = 500;          // same cap as CMSNEO's Dynamic Reports upload
        private const long BulkMaxBytes = 10 * 1024 * 1024;

        private class ReportSnapshot
        {
            public List<string> Columns = new List<string>();                 // report data columns, header order
            public List<Dictionary<string, object>> Rows;                     // NameReportColumns output
            public Dictionary<string, int> IdByRowId = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            public Dictionary<int, string> RowIdById = new Dictionary<int, string>();
            public string Name = "Report";
        }

        private ReportSnapshot Snapshot(int messageItemId, int uid, string reportId)
        {
            var dat = DB.GetDB("exec MBX_GetDRItemReportRows @uid, @messageItemId", uid,
                new JObject { ["messageItemId"] = messageItemId }.ToString());
            if (dat.Columns.Contains("err")) return null;

            var snap = new ReportSnapshot { Rows = NameReportColumns(dat) };
            foreach (var r in snap.Rows)
                foreach (var k in r.Keys)
                    if (!MetaColumns.Contains(k) && !snap.Columns.Contains(k)) snap.Columns.Add(k);
            if (dat.Rows.Count > 0 && dat.Columns.Contains("DR_ReportName") && dat.Rows[0]["DR_ReportName"] != DBNull.Value)
                snap.Name = dat.Rows[0]["DR_ReportName"].ToString();

            var ids = DB.GetDB("select id, RowID from NEO_DynamicReports where ReportID = @reportid and active = 1", uid,
                new JObject { ["reportid"] = reportId }.ToString());
            if (ids.Columns.Contains("RowID"))
                foreach (DataRow r in ids.Rows)
                {
                    if (r["RowID"] == DBNull.Value) continue;
                    int id = Convert.ToInt32(r["id"]);
                    string rowId = r["RowID"].ToString();
                    snap.IdByRowId[rowId] = id;
                    snap.RowIdById[id] = rowId;
                }
            return snap;
        }

        private static string Cell(object v) =>
            v == null || v == DBNull.Value ? "" : (v is DateTime dt ? dt.ToString("yyyy-MM-dd") : v.ToString());

        // Header names compare the way NEO_DynamicRecordUpdate matches keys (letters/digits/_ only).
        private static string NormHeader(string h) =>
            new string((h ?? "").Trim().Replace(" ", "_").Where(ch => char.IsLetterOrDigit(ch) || ch == '_').ToArray()).ToLowerInvariant();

        // Adding rows (2026-11-18): only the report's own company can (NEO_DynamicRecordUpdate's
        // @fid = 0 path checks that too). Here: one of the report's rows must pass RowAccess with
        // IsMine for this item, which also rules out a read-only task share.
        private bool CanAddRows(int messageItemId, int uid, ReportSnapshot snap)
        {
            var mineRow = snap.Rows.FirstOrDefault(r => r.TryGetValue("xxxIsMine", out var m) && m is bool b && b);
            if (mineRow == null) return false;
            var access = RowAccess(messageItemId, uid, Convert.ToInt32(mineRow["xxxID"]));
            return access != null && access.IsMine;
        }

        private static bool AddRow(int uid, string reportId, List<string> keys, List<string> vals)
        {
            var res = DB.GetDB("exec NEO_DynamicRecordUpdate @uid, @fid, @keys, @vals, @reportid", uid,
                new JObject
                {
                    ["fid"] = 0,
                    ["keys"] = string.Join(",", keys.Select(k => (k ?? "").Replace(",", ""))),
                    ["vals"] = string.Join("|", vals.Select(v => (v ?? "").Replace("|", ""))),
                    ["reportid"] = reportId
                }.ToString());
            return !res.Columns.Contains("err");
        }

        // Add Record: { Keys, Vals } with the report's column names, like Submit Changes.
        [HttpPost("item/{messageItemId:int}/report/rows")]
        public IActionResult AddRecord(int messageItemId, [FromBody] RowUpdate req)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049
            string reportId = ReportFor(messageItemId, uid);
            if (reportId == null) return NotFound();
            if (req?.Keys == null || req.Vals == null || req.Keys.Count != req.Vals.Count) return BadRequest();

            var snap = Snapshot(messageItemId, uid, reportId);
            if (snap == null || !CanAddRows(messageItemId, uid, snap)) return NotFound();

            // only the report's own columns
            var keys = new List<string>(); var vals = new List<string>();
            for (int i = 0; i < req.Keys.Count; i++)
                if (snap.Columns.Contains(req.Keys[i])) { keys.Add(req.Keys[i]); vals.Add(req.Vals[i] ?? ""); }
            if (keys.Count == 0 || vals.All(string.IsNullOrWhiteSpace)) return BadRequest();

            if (!AddRow(uid, reportId, keys, vals)) return StatusCode(500);
            LogAccess(messageItemId, uid, "Served", "DR row added");
            return Ok();
        }

        [HttpGet("item/{messageItemId:int}/report/export")]
        public IActionResult ExportForUpdate(int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049
            string reportId = ReportFor(messageItemId, uid);
            if (reportId == null) return NotFound();

            var snap = Snapshot(messageItemId, uid, reportId);
            if (snap == null) return NotFound();
            var mine = snap.Rows.Where(r => r.TryGetValue("xxxIsMine", out var m) && m is bool b && b).ToList();
            if (mine.Count == 0) return StatusCode(409, new { status = "no_rows_of_yours" });

            var headers = new List<string> { "RowID" };
            headers.AddRange(snap.Columns);
            var rows = mine.Select(r =>
            {
                int id = Convert.ToInt32(r["xxxID"]);
                var vals = new List<string> { snap.RowIdById.TryGetValue(id, out var g) ? g : "" };
                vals.AddRange(snap.Columns.Select(c => r.TryGetValue(c, out var v) ? Cell(v) : ""));
                return (IList<string>)vals;
            }).ToList();

            LogAccess(messageItemId, uid, "Served", "DR bulk export (" + rows.Count + " rows)");
            var safe = new string(snap.Name.Where(ch => char.IsLetterOrDigit(ch) || ch == ' ' || ch == '_' || ch == '-').ToArray()).Trim();
            return File(XlsxLite.Write(headers, rows, safe), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                (safe == "" ? "Report" : safe) + " - Update.xlsx");
        }

        [HttpPost("item/{messageItemId:int}/report/bulk")]
        [RequestSizeLimit(BulkMaxBytes + 64 * 1024)]
        public IActionResult BulkUpdate(int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049
            string reportId = ReportFor(messageItemId, uid);
            if (reportId == null) return NotFound();
            if (Request.Form.Files.Count == 0) return Ok(new { status = "file_required" });
            var file = Request.Form.Files[0];
            if (file.Length > BulkMaxBytes) return Ok(new { status = "file_too_large" });

            List<string> fileHeaders; List<Dictionary<string, string>> fileRows;
            try
            {
                using var ms = new MemoryStream(); file.CopyTo(ms);
                (fileHeaders, fileRows) = XlsxLite.Read(ms.ToArray());
            }
            catch { return Ok(new { status = "file_unreadable" }); }

            string rowIdHeader = fileHeaders.FirstOrDefault(h => string.Equals(h, "RowID", StringComparison.OrdinalIgnoreCase));
            if (rowIdHeader == null) return Ok(new { status = "rowid_required" });
            if (fileRows.Count > BulkMaxRows) return Ok(new { status = "too_many_rows", max = BulkMaxRows });

            var snap = Snapshot(messageItemId, uid, reportId);
            if (snap == null) return NotFound();

            // File columns that are report columns (by normalized name); the rest are ignored.
            var colByNorm = snap.Columns.GroupBy(NormHeader).ToDictionary(g => g.Key, g => g.First());
            var skipCols = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "RowID", "Company_Loaded_By", "Status", "Attachments", "FID", "ReportID", "Sorted_By" };
            var map = new List<(string FileHeader, string Column)>();
            var ignored = new List<string>();
            foreach (var h in fileHeaders.Where(h => h != ""))
            {
                if (skipCols.Contains(h.Trim()) || skipCols.Contains(h.Trim().Replace(" ", "_"))) continue;
                if (colByNorm.TryGetValue(NormHeader(h), out var col) && !map.Any(m => m.Column == col)) map.Add((h, col));
                else ignored.Add(h);
            }
            if (map.Count == 0) return Ok(new { status = "no_matching_columns" });

            var rowById = snap.Rows.ToDictionary(r => Convert.ToInt32(r["xxxID"]), r => r);
            int updated = 0, unchanged = 0, added = 0, noRowId = 0, notFound = 0, notYours = 0, failed = 0;
            bool? canAdd = null;   // worked out on the first row that needs it
            var problems = new List<string>();

            for (int i = 0; i < fileRows.Count; i++)
            {
                var fr = fileRows[i];
                string line = "row " + (i + 2);
                string rid = (fr.TryGetValue(rowIdHeader, out var x) ? x : "").Trim();
                if (rid == "")
                {
                    // 2026-11-18: a row with no RowID is a new record (your company's report only).
                    var nk = new List<string>(); var nvals = new List<string>();
                    foreach (var (fh, col) in map) { nk.Add(col); nvals.Add((fr.TryGetValue(fh, out var v0) ? v0 : "") ?? ""); }
                    if (nvals.All(string.IsNullOrWhiteSpace)) continue;
                    if (canAdd == null) canAdd = CanAddRows(messageItemId, uid, snap);
                    if (canAdd != true) { noRowId++; if (problems.Count < 10) problems.Add(line + ": new rows can only be added by the report's own company"); continue; }
                    if (AddRow(uid, reportId, nk, nvals)) added++;
                    else { failed++; if (problems.Count < 10) problems.Add(line + ": the new row couldn't be added"); }
                    continue;
                }
                if (!snap.IdByRowId.TryGetValue(rid, out int drid) || !rowById.TryGetValue(drid, out var cur))
                {
                    notFound++; if (problems.Count < 10) problems.Add(line + ": RowID not in this report"); continue;
                }

                var keys = new List<string>(); var vals = new List<string>();
                foreach (var (fh, col) in map)
                {
                    string nv = (fr.TryGetValue(fh, out var v) ? v : "") ?? "";
                    string ov = cur.TryGetValue(col, out var o) ? Cell(o) : "";
                    if (!string.Equals(nv.Trim(), ov.Trim(), StringComparison.Ordinal)) { keys.Add(col); vals.Add(nv); }
                }
                if (keys.Count == 0) { unchanged++; continue; }

                // Same check as Submit Changes, only for rows that actually change.
                var access = RowAccess(messageItemId, uid, drid);
                if (access == null || !access.IsMine)
                {
                    notYours++; if (problems.Count < 10) problems.Add(line + ": not your company's row"); continue;
                }

                var res = DB.GetDB("exec NEO_DynamicRecordUpdate @uid, @fid, @keys, @vals, @reportid", uid,
                    new JObject
                    {
                        ["fid"] = -drid,
                        ["keys"] = string.Join(",", keys.Select(k => k.Replace(",", ""))),
                        ["vals"] = string.Join("|", vals.Select(v => v.Replace("|", ""))),
                        ["reportid"] = ""
                    }.ToString());
                if (res.Columns.Contains("err")) { failed++; if (problems.Count < 10) problems.Add(line + ": update failed"); }
                else updated++;
            }

            LogAccess(messageItemId, uid, "Served", "DR bulk update: " + updated + " updated, " + added + " added, " + unchanged + " unchanged, " +
                (notFound + notYours + noRowId + failed) + " skipped");
            return Ok(new { status = "ok", updated, added, unchanged, noRowId, notFound, notYours, failed, ignored, problems });
        }

        // Header names NEO_GetDynamicReportsALL2 leaves out of the data columns.
        private static readonly HashSet<string> SkippedHeaders = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "RowID", "ReportID", "FID", "Company_Loaded_By" };
        private static readonly HashSet<string> MetaColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            { "xxxIX", "xxxID", "xCID", "Company_Loaded_By", "Status", "xxxIsMine", "DR_ReportID", "DR_ReportType", "DR_ReportName", "hdrs", "Attachments" };

        // One object per row: the meta columns, then the report's own columns named from the row's
        // comma-separated headers (position N = ColN, spaces -> "_", names of 2 characters or less
        // and the SkippedHeaders left out), the same naming NEO_GetDynamicReportsALL2 uses.
        private static List<Dictionary<string, object>> NameReportColumns(DataTable dat)
        {
            var rows = new List<Dictionary<string, object>>();
            foreach (DataRow r in dat.Rows)
            {
                var o = new Dictionary<string, object>();
                foreach (var m in MetaColumns)
                    if (dat.Columns.Contains(m)) o[m] = r[m] == DBNull.Value ? null : r[m];

                var headers = (r["hdrs"] == DBNull.Value ? "" : r["hdrs"].ToString()).Split(',');
                for (int i = 0; i < headers.Length && i < 100; i++)
                {
                    string h = headers[i];
                    if (h.TrimEnd().Length <= 2 || SkippedHeaders.Contains(h.Trim())) continue;
                    string name = h.Replace(" ", "_");
                    if (o.ContainsKey(name) || MetaColumns.Contains(name)) continue;
                    string col = "Col" + (i + 1);
                    o[name] = dat.Columns.Contains(col) && r[col] != DBNull.Value ? r[col] : null;
                }
                rows.Add(o);
            }
            return rows;
        }

        // One row: its fields (NEO_GetDynamicReportFile, the same proc CMSNEO's Dynamic
        // Record Options uses, so the keys match what NEO_DynamicRecordUpdate expects),
        // attachments, notes, and the companies a new note can be shared with.
        [HttpGet("item/{messageItemId:int}/report/row/{drid:int}")]
        public IActionResult Row(int messageItemId, int drid)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049

            var row = RowAccess(messageItemId, uid, drid);
            if (row == null) return NotFound();

            var fields = DB.GetDB("exec NEO_GetDynamicReportFile @uid, @fid, @getCID, @allowEmpty, @reportid", uid,
                new JObject { ["fid"] = -drid, ["getCID"] = 1, ["allowEmpty"] = 1, ["reportid"] = "" }.ToString());
            var docs = DB.GetDB("exec NEO_DynamicReports_GetDocs @uid, @drid", uid, new JObject { ["drid"] = drid }.ToString());

            // Which attachments this user uploaded (only those get a Delete button —
            // DeleteDoc enforces the same rule).
            if (docs.Columns.Contains("FID"))
            {
                var mineDat = DB.GetDB("select FID from NEO_DynamicReportDocs where DR_ID = @drid and uid = @uid and active = 1", uid,
                    new JObject { ["drid"] = drid }.ToString());
                var mineFids = mineDat.Columns.Contains("FID")
                    ? mineDat.Rows.Cast<DataRow>().Select(r => r["FID"].ToString()).ToHashSet()
                    : new HashSet<string>();
                docs.Columns.Add("IsMine", typeof(bool));
                foreach (DataRow d in docs.Rows) d["IsMine"] = mineFids.Contains(d["FID"].ToString());
            }
            var notes = DB.GetDB("exec NEO_GetFileNotes @uid, @fid", uid, new JObject { ["fid"] = -drid }.ToString());
            var shares = DB.GetDB("exec MBX_GetDRShareCompanies @uid, @messageItemId, @drid", uid,
                new JObject { ["messageItemId"] = messageItemId, ["drid"] = drid }.ToString());

            LogAccess(messageItemId, uid, "Served", "DR row " + drid);
            return Ok(new
            {
                isMine = row.IsMine,
                myUID = uid,
                fields = JsonConvert.SerializeObject(fields),
                docs = JsonConvert.SerializeObject(docs),
                notes = JsonConvert.SerializeObject(notes),
                shareCompanies = JsonConvert.SerializeObject(shares)
            });
        }

        public class RowUpdate { public List<string> Keys { get; set; } public List<string> Vals { get; set; } }

        // Submit Changes. Same call CMSNEO's DRO_SubmitChanges makes: keys joined by
        // ",", values by "|" (so "|" is stripped from values — CMSNEO's own client
        // means to do the same, but its regex is a no-op).
        [HttpPost("item/{messageItemId:int}/report/row/{drid:int}")]
        public IActionResult UpdateRow(int messageItemId, int drid, [FromBody] RowUpdate req)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049

            var row = RowAccess(messageItemId, uid, drid);
            if (row == null || !row.IsMine) return NotFound();
            if (req?.Keys == null || req.Vals == null || req.Keys.Count != req.Vals.Count || req.Keys.Count == 0) return BadRequest();

            DB.GetDB("exec NEO_DynamicRecordUpdate @uid, @fid, @keys, @vals, @reportid", uid,
                new JObject
                {
                    ["fid"] = -drid,
                    ["keys"] = string.Join(",", req.Keys.Select(k => (k ?? "").Replace(",", ""))),
                    ["vals"] = string.Join("|", req.Vals.Select(v => (v ?? "").Replace("|", ""))),
                    ["reportid"] = ""
                }.ToString());

            LogAccess(messageItemId, uid, "Served", "DR row " + drid + " updated");
            return Ok();
        }

        [HttpGet("item/{messageItemId:int}/report/row/{drid:int}/docs/{fid:int}")]
        public IActionResult Doc(int messageItemId, int drid, int fid)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049
            if (RowAccess(messageItemId, uid, drid) == null) return NotFound();

            var dat = DB.GetDB("select Filename, FileData from NEO_DynamicReportDocs where FID = @fid and DR_ID = @drid and active = 1", uid,
                new JObject { ["fid"] = fid, ["drid"] = drid }.ToString());
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err") || !(dat.Rows[0]["FileData"] is byte[] bytes)) return NotFound();

            LogAccess(messageItemId, uid, "Served", "DR attachment " + fid);
            return File(bytes, "application/octet-stream", dat.Rows[0]["Filename"]?.ToString() ?? "attachment");
        }

        [HttpPost("item/{messageItemId:int}/report/row/{drid:int}/docs")]
        [DisableRequestSizeLimit]
        public IActionResult AddDocs(int messageItemId, int drid)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049
            if (RowAccess(messageItemId, uid, drid) == null) return NotFound();
            if (Request.Form.Files.Count == 0) return BadRequest();

            // Binary parameter — DB.GetDB can't pass bytes, so this is a direct call,
            // the same way IaViewerController.RunAttachSql does it.
            foreach (var file in Request.Form.Files)
            {
                byte[] bytes;
                using (var ms = new MemoryStream()) { file.CopyTo(ms); bytes = ms.ToArray(); }

                using var da = new SqlDataAdapter("exec NEO_DynamicReport_AttachDoc @uid, @filename, @filedata, @drid", DB.ConnectionString);
                da.SelectCommand.CommandTimeout = 180;
                da.SelectCommand.Parameters.AddWithValue("@uid", uid);
                da.SelectCommand.Parameters.AddWithValue("@filename", file.FileName);
                da.SelectCommand.Parameters.Add("@filedata", SqlDbType.VarBinary, -1).Value = bytes;
                da.SelectCommand.Parameters.AddWithValue("@drid", drid);
                da.Fill(new DataTable());
            }

            LogAccess(messageItemId, uid, "Served", "DR row " + drid + ": " + Request.Form.Files.Count + " attachment(s) added");
            return Ok();
        }

        [HttpDelete("item/{messageItemId:int}/report/row/{drid:int}/docs/{fid:int}")]
        public IActionResult DeleteDoc(int messageItemId, int drid, int fid)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049
            if (RowAccess(messageItemId, uid, drid) == null) return NotFound();

            var mine = DB.GetDB("select FID from NEO_DynamicReportDocs where FID = @fid and DR_ID = @drid and uid = @uid and active = 1", uid,
                new JObject { ["fid"] = fid, ["drid"] = drid }.ToString());
            if (mine.Rows.Count == 0 || mine.Columns.Contains("err")) return NotFound();

            DB.GetDB("exec NEO_DynamicReport_DeleteDoc @uid, @fid", uid, new JObject { ["fid"] = fid }.ToString());
            LogAccess(messageItemId, uid, "Served", "DR attachment " + fid + " deleted");
            return Ok();
        }

        public class NoteRequest { public string Note { get; set; } public List<int> ShareWith { get; set; } }

        // Share-with companies must come from MBX_GetDRShareCompanies — never trust the
        // client's list.
        [HttpPost("item/{messageItemId:int}/report/row/{drid:int}/notes")]
        public IActionResult AddNote(int messageItemId, int drid, [FromBody] NoteRequest req)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049
            if (RowAccess(messageItemId, uid, drid) == null) return NotFound();
            if (string.IsNullOrWhiteSpace(req?.Note)) return BadRequest();

            var allowed = DB.GetDB("exec MBX_GetDRShareCompanies @uid, @messageItemId, @drid", uid,
                new JObject { ["messageItemId"] = messageItemId, ["drid"] = drid }.ToString());
            var allowedCids = allowed.Columns.Contains("CID")
                ? allowed.Rows.Cast<DataRow>().Select(r => Convert.ToInt32(r["CID"])).ToHashSet()
                : new HashSet<int>();
            var share = (req.ShareWith ?? new List<int>()).Where(allowedCids.Contains).Distinct();

            DB.GetDB("exec NEO_InsUpdDelFileNotes @uid, @type, @fid, @nid, @Note, @xCIDs", uid,
                new JObject
                {
                    ["type"] = "I",
                    ["fid"] = -drid,
                    ["nid"] = "",
                    ["Note"] = req.Note.Trim(),
                    ["xCIDs"] = string.Join(",", share)
                }.ToString());

            LogAccess(messageItemId, uid, "Served", "DR row " + drid + ": note added");
            return Ok();
        }

        [HttpDelete("item/{messageItemId:int}/report/row/{drid:int}/notes/{nid}")]
        public IActionResult DeleteNote(int messageItemId, int drid, string nid)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            uid = ActAs(messageItemId, uid);   // sql/049
            if (RowAccess(messageItemId, uid, drid) == null) return NotFound();
            if (!Guid.TryParse(nid, out _)) return BadRequest();

            var mine = DB.GetDB("select top 1 1 as x from Neo_FileNotes where NID = @nid and FID = @fid and uid = @uid and active = 1", uid,
                new JObject { ["nid"] = nid, ["fid"] = -drid }.ToString());
            if (mine.Rows.Count == 0 || mine.Columns.Contains("err")) return NotFound();

            DB.GetDB("exec NEO_InsUpdDelFileNotes @uid, @type, @fid, @nid, @Note, @xCIDs", uid,
                new JObject { ["type"] = "D", ["fid"] = -drid, ["nid"] = nid, ["Note"] = "", ["xCIDs"] = "" }.ToString());
            LogAccess(messageItemId, uid, "Served", "DR row " + drid + ": note deleted");
            return Ok();
        }

        // sql/049 (2026-11-18): an "update an existing report" task assigned to a management user's
        // account AT the report's company. When that same person (same email, MBX_IsTaskAssigneeOwner)
        // signs in with their management account, act as the assigned account, so the gates see the
        // message's recipient and edits / new rows belong to the report's company (as for exams,
        // IaViewerController.Exam.cs ActAsUID, sql/044). Anyone else keeps their own UID.
        private static int ActAs(int messageItemId, int uid)
        {
            var a = DB.GetDB(
                "select top 1 t.AssignedToUID from MBX_Task t " +
                "join MBX_MessageItem mi on mi.MessageItemID = t.MessageItemID " +
                "cross apply (select top 1 dbo.mycid(dr.CreatedBy) OwnerCID from NEO_DynamicReports dr where dr.ReportID = mi.ItemID and dr.active = 1 order by dr.id) o " +
                "where t.MessageItemID = @messageItemId and t.TaskType = 'DRUpdate' and t.Status <> 'Cancelled' " +
                "and t.AssignedToUID <> @uid and dbo.mycid(@uid) <> o.OwnerCID and dbo.mycid(t.AssignedToUID) = o.OwnerCID " +
                "and dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @uid) = 1 " +
                "and exists (select 1 from Users au where au.UID = t.AssignedToUID and au.Active = 1)",
                uid, new JObject { ["messageItemId"] = messageItemId }.ToString());
            return (a.Rows.Count > 0 && !a.Columns.Contains("err") && a.Columns.Contains("AssignedToUID"))
                ? Convert.ToInt32(a.Rows[0]["AssignedToUID"]) : uid;
        }

        private string ReportFor(int messageItemId, int uid)
        {
            var dat = DB.GetDB("exec MBX_GetDRItemReport @uid, @messageItemId", uid,
                new JObject { ["messageItemId"] = messageItemId }.ToString());
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err"))
            {
                LogAccess(messageItemId, uid, "Denied", "DR report: not a participant, or not a completed report item");
                return null;
            }
            return dat.Rows[0]["ReportID"].ToString();
        }

        private class RowInfo { public bool IsMine; }

        private RowInfo RowAccess(int messageItemId, int uid, int drid)
        {
            var dat = DB.GetDB("exec MBX_GetDRRowAccess @uid, @messageItemId, @drid", uid,
                new JObject { ["messageItemId"] = messageItemId, ["drid"] = drid }.ToString());
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err"))
            {
                LogAccess(messageItemId, uid, "Denied", "DR row " + drid + ": not in this report, or no access");
                return null;
            }
            return new RowInfo { IsMine = Convert.ToBoolean(dat.Rows[0]["IsMine"]) };
        }

        private static void LogAccess(int messageItemId, int uid, string result, string detail)
        {
            DB.GetDB("exec MBX_LogAccess @messageItemId, @byUid, @result, @detail", uid,
                new JObject { ["messageItemId"] = messageItemId, ["byUid"] = uid, ["result"] = result, ["detail"] = detail ?? "" }.ToString());
        }
    }
}
