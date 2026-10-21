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

            string reportId = ReportFor(messageItemId, uid);
            if (reportId == null) return NotFound();

            var dat = DB.GetDB("exec NEO_GetDynamicReportsALL2 @uid, @justHdrs, @filter", uid,
                new JObject { ["justHdrs"] = 0, ["filter"] = "ReportID~" + reportId }.ToString());
            if (dat.Columns.Contains("err")) return NotFound();

            LogAccess(messageItemId, uid, "Served", "DR report");
            return Content(JsonConvert.SerializeObject(dat), "application/json");
        }

        // One row: its fields (NEO_GetDynamicReportFile, the same proc CMSNEO's Dynamic
        // Record Options uses, so the keys match what NEO_DynamicRecordUpdate expects),
        // attachments, notes, and the companies a new note can be shared with.
        [HttpGet("item/{messageItemId:int}/report/row/{drid:int}")]
        public IActionResult Row(int messageItemId, int drid)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

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
