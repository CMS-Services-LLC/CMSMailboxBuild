using System;
using System.Collections.Generic;
using System.Data;
using System.IO;
using System.Linq;
using Microsoft.AspNetCore.Mvc;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace CMSMailbox.Controllers
{
    // Exam tasks (sql/019-020, WizardAssignments_Plan.md Phase 3). The assignee, a user at
    // the examined company, works the exam in exam-viewer.html, which runs CMSNEO's own
    // managementExamsNEW.js copied UNCHANGED (all mailbox adaptations live in that host
    // page). Its scripts post to the same main/adHoc and main/adHocAttach as the form
    // viewer, and IaViewerController hands ExamTask items to the methods below.
    //
    // Two roles (sql/020, MBX_GetExamAccess), on the original ExamTask item or an
    // ExamRef copy a reply carries:
    //   Assignee - the examined company's own view (answers, document requests);
    //   Assigner - the management view: also scoring and audit layers.
    //
    // CMSNEO's exam procs check nothing about the caller (NEO_MgtUpdateAnswers,
    // NEO_MgtUpdateAnswer, NEO_MgtArchiveAnswer, NEO_MgtDeleteFormDoc, NEO_MgtUpdateLMC,
    // ... write whatever they're given). So every call here:
    //   1. passes MBX_GetExamAccess: the caller is the task's assignee or assigner, on a
    //      message they received or sent, their company tree reaches the examined
    //      company (AccessTreeDown, same rule as exam snapshots), and the exam is still
    //      shared with that company;
    //   2. is on the allowlist for the caller's role (no heatmap report, PDF, zip,
    //      snapshots or CMS-file attach for either; scoring writes for the Assigner only);
    //   3. is pinned to the task: any examid must be the task's, any xcid becomes the
    //      examined company; answer edits/archives must be the task exam's answers written
    //      by the caller's company; deletes must be the caller's own upload on that exam;
    //   4. writes stop when CanWrite = 0 (Assignee: Completed; Assigner: Cancelled).
    // The assignee's first answer or upload moves the task Open → Pending Review
    // (MBX_MarkExamTaskStarted).
    public partial class IaViewerController
    {
        private static readonly HashSet<string> ExamReadActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "_MgtGetExam", "_MgtGetExamScoring", "_MgtGetHeatmapTypes", "_MgtGetExamDocs",
            "_MgtGetAuditButtons", "_MgtGetJSScoring", "_MgtGetForm", "_MgtGetHeatmapStaticPages",
            "_MGTGetLastView", "_MgtGetExamAnswers", "_MgtGetExamScores",
            // Which panels were open last time — per-user UI state, not exam content.
            "_MGTUpdateLastView"
        };

        // Content writes: require CanWrite; the assignee's mark the task started.
        private static readonly HashSet<string> ExamWriteActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "_MgtUpdateAnswers", "_MgtUpdateAnswer", "_MgtArchiveAnswer", "_MgtDeleteFormDoc"
        };

        // Management view only (scoring): the Assigner role.
        private static readonly HashSet<string> ExamAssignerWriteActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "_SetExamDefaultScores", "_MgtUpdateLMC"
        };

        private class ExamTaskContext
        {
            public string ExamID, ExamName, ExamCompany, TaskStatus, Role;
            public int ExamCID, OriginItemID;
            public bool CanWrite;
            public bool IsAssigner => Role == "Assigner";
        }

        private static bool IsExamItem(int messageItemId)
        {
            var dat = DB.GetDB("select ItemType from MBX_MessageItem where MessageItemID = @messageItemId", 0,
                "{\"messageItemId\":" + messageItemId + "}");
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err")) return false;
            var t = dat.Rows[0]["ItemType"].ToString();
            return t == "ExamTask" || t == "ExamRef";
        }

        private static ExamTaskContext ResolveExamTask(int messageItemId, int uid)
        {
            var dat = DB.GetDB("exec MBX_GetExamAccess @uid, @messageItemId", uid, "{\"messageItemId\":" + messageItemId + "}");
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err"))
            {
                LogAccess(messageItemId, uid, "Denied", "exam: not this exam task's assignee or assigner, or no access to the examined company/exam");
                return null;
            }
            var r = dat.Rows[0];
            return new ExamTaskContext
            {
                ExamID = r["ExamID"].ToString(),
                ExamCID = Convert.ToInt32(r["ExamCID"]),
                ExamName = r["ExamName"]?.ToString() ?? "",
                ExamCompany = r["ExamCompany"]?.ToString() ?? "",
                TaskStatus = r["TaskStatus"]?.ToString() ?? "",
                Role = r["Role"]?.ToString() ?? "",
                OriginItemID = Convert.ToInt32(r["OriginItemID"]),
                CanWrite = Convert.ToBoolean(r["CanWrite"])
            };
        }

        // What exam-viewer.html needs to stand the copied viewer up: the exam, and the
        // handful of globals CMS's Documents page normally provides.
        [HttpGet("exam/{messageItemId:int}/bootstrap")]
        public IActionResult ExamBootstrap(int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

            var ctx = ResolveExamTask(messageItemId, uid);
            if (ctx == null) return NotFound();

            var me = DB.GetDB("select dbo.mycid(u.UID) as MyCID, c.Company as MyCompany, u.Fname as FName, u.Lname as LName " +
                "from Users u left join Companies c on c.CID = dbo.mycid(u.UID) where u.UID = @uid", uid);
            var security = DB.GetDB("exec NEO_NewSecurity @uid", uid);

            LogAccess(messageItemId, uid, "Served", "exam bootstrap");
            return Ok(new
            {
                examId = ctx.ExamID,
                examName = ctx.ExamName,
                examCID = ctx.ExamCID,
                examCompany = ctx.ExamCompany,
                taskStatus = ctx.TaskStatus,
                canWrite = ctx.CanWrite,
                role = ctx.Role,
                myUID = uid,
                myCID = me.Rows.Count > 0 ? me.Rows[0]["MyCID"] : null,
                myCompany = me.Rows.Count > 0 ? me.Rows[0]["MyCompany"]?.ToString() : "",
                fName = me.Rows.Count > 0 ? me.Rows[0]["FName"]?.ToString() : "",
                lName = me.Rows.Count > 0 ? me.Rows[0]["LName"]?.ToString() : "",
                security = JsonConvert.SerializeObject(security)
            });
        }

        private IActionResult ExamAdHoc(string action, string strjson, int messageItemId, int uid)
        {
            var ctx = ResolveExamTask(messageItemId, uid);
            if (ctx == null) return Content("[]");

            bool isWrite = ExamWriteActions.Contains(action ?? "") || (ctx.IsAssigner && ExamAssignerWriteActions.Contains(action ?? ""));
            if (!isWrite && !ExamReadActions.Contains(action ?? ""))
            {
                LogAccess(messageItemId, uid, "Denied", "exam: action not on allowlist: " + action);
                return Content("[]");
            }
            if (isWrite && !ctx.CanWrite)
            {
                LogAccess(messageItemId, uid, "Denied", "exam: task is " + ctx.TaskStatus + ", no more changes: " + action);
                return Content("[]");
            }

            var jo = string.IsNullOrEmpty(strjson) ? new JObject() : JObject.Parse(strjson);
            string why = PinToExamTask(jo, ctx);
            if (why == null) why = CheckExamWrite(action, jo, ctx, uid);
            if (why != null)
            {
                LogAccess(messageItemId, uid, "Denied", "exam: " + action + ": " + why);
                return Content("[]");
            }

            string strParams = "";
            foreach (var key in jo) strParams += ", @" + key.Key;
            var dat = DB.GetDB("exec NEO" + action + " @uid" + strParams, uid, jo.ToString(Formatting.None));

            if (isWrite && !ctx.IsAssigner && !dat.Columns.Contains("err") &&
                (string.Equals(action, "_MgtUpdateAnswers", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(action, "_MgtUpdateAnswer", StringComparison.OrdinalIgnoreCase)))
            {
                MarkExamStarted(ctx.OriginItemID, uid);
            }

            LogAccess(messageItemId, uid, "Served", "exam: " + action);
            return Content(JsonConvert.SerializeObject(dat), "application/json");
        }

        // Document-request upload (managementExamsNEW.js's MGTUploadDocsGO). Only
        // _MGTExamUploadDoc, pinned to the task's exam and company, uploaded as the
        // caller themself (xuid 0 — never on behalf of another account), and only into a
        // document request that really is on that exam.
        private IActionResult ExamAdHocAttach(string action, string strjson, int messageItemId, int uid)
        {
            var ctx = ResolveExamTask(messageItemId, uid);
            if (ctx == null) return Content("[]");

            if (!string.Equals(action, "_MGTExamUploadDoc", StringComparison.OrdinalIgnoreCase))
            {
                LogAccess(messageItemId, uid, "Denied", "exam: adHocAttach action not on allowlist: " + action);
                return Content("[]");
            }
            if (!ctx.CanWrite)
            {
                LogAccess(messageItemId, uid, "Denied", "exam: task is " + ctx.TaskStatus + ", no more uploads");
                return Content("[]");
            }

            var jo = string.IsNullOrEmpty(strjson) ? new JObject() : JObject.Parse(strjson);
            string why = PinToExamTask(jo, ctx);
            if (why == null)
            {
                jo["xuid"] = 0;
                string lineid = jo["lineid"]?.ToString() ?? "", docreqid = jo["docreqid"]?.ToString() ?? "";
                var dr = DB.GetDB(
                    "select top 1 1 as x from a_aMGTExamDocRequest r " +
                    "join a_aMgtExamBody b on b.LineID = r.LineID and b.ExamID = @examid and b.Active = 1 " +
                    "where r.LineID = @lineid and r.DocReqID = @docreqid and r.Active = 1", uid,
                    new JObject { ["examid"] = ctx.ExamID, ["lineid"] = lineid, ["docreqid"] = docreqid }.ToString());
                if (dr.Rows.Count == 0 || dr.Columns.Contains("err")) why = "document request is not on this exam";
            }
            if (why != null)
            {
                LogAccess(messageItemId, uid, "Denied", "exam: upload: " + why);
                return Content("[]");
            }

            string rtn = "[]";
            foreach (var file in Request.Form.Files)
            {
                byte[] filedata;
                using (var ms = new MemoryStream()) { file.CopyTo(ms); filedata = ms.ToArray(); }
                rtn = JsonConvert.SerializeObject(RunAttachSql(action, file.FileName, filedata, jo, uid));
            }

            if (Request.Form.Files.Count > 0 && !ctx.IsAssigner) MarkExamStarted(ctx.OriginItemID, uid);
            LogAccess(messageItemId, uid, "Served", "exam: " + Request.Form.Files.Count + " document(s) uploaded");
            return Content(rtn, "application/json");
        }

        // A document-request file, served by the mailbox itself after checking it's on
        // the task's exam and company (CMSNEO's DownloadExamFile resolves files through
        // the user's CMS file cache, which isn't kept current for mailbox users).
        // PDFs and images display inline; everything else downloads.
        [HttpGet("exam/{messageItemId:int}/doc/{fid:int}")]
        public IActionResult ExamDoc(int messageItemId, int fid, int dl = 0)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

            var ctx = ResolveExamTask(messageItemId, uid);
            if (ctx == null) return NotFound();

            fid = Math.Abs(fid);
            var dat = DB.GetDB(
                "select case when d.LinkedFID is not null then f.FileName else d.Filename end as Filename, " +
                "case when d.LinkedFID is not null then fd.FileData else d.Filedata end as FileData " +
                "from a_aMGTExamDocs d left join files f on f.fid = d.LinkedFID " +
                "left join FileData fd on fd.fid = f.fid and fd.isDispute = 0 " +
                "where d.FID = @fid and d.ExamID = @examid and d.xCID = @xcid and d.Active = 1", uid,
                new JObject { ["fid"] = fid, ["examid"] = ctx.ExamID, ["xcid"] = ctx.ExamCID }.ToString());
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err") || !(dat.Rows[0]["FileData"] is byte[] bytes))
            {
                LogAccess(messageItemId, uid, "Denied", "exam: document " + fid + " is not on this exam");
                return NotFound();
            }

            string filename = dat.Rows[0]["Filename"]?.ToString() ?? "document";
            string ext = Path.GetExtension(filename).TrimStart('.').ToLowerInvariant();
            var inline = new Dictionary<string, string>
            {
                ["pdf"] = "application/pdf", ["png"] = "image/png", ["jpg"] = "image/jpeg",
                ["jpeg"] = "image/jpeg", ["gif"] = "image/gif", ["txt"] = "text/plain"
            };

            LogAccess(messageItemId, uid, "Served", "exam: document " + fid);
            if (dl == 0 && inline.TryGetValue(ext, out var ct)) return File(bytes, ct);
            return File(bytes, "application/octet-stream", filename);
        }

        // Returns null if OK, else the reason. Any examid must be the task's; any xcid
        // (0 = "my company" in the copied viewer) becomes the examined company.
        private static string PinToExamTask(JObject jo, ExamTaskContext ctx)
        {
            foreach (var p in jo.Properties().ToList())
            {
                string val = p.Value?.ToString() ?? "";
                if (string.Equals(p.Name, "examid", StringComparison.OrdinalIgnoreCase))
                {
                    if (!string.Equals(val, ctx.ExamID, StringComparison.OrdinalIgnoreCase)) return "examid is not the task's exam";
                }
                else if (string.Equals(p.Name, "xcid", StringComparison.OrdinalIgnoreCase))
                {
                    if (val != "0" && val != ctx.ExamCID.ToString()) return "xcid is not the examined company";
                    p.Value = ctx.ExamCID;
                }
            }
            return null;
        }

        // Per-action ownership checks for the writes that name a line, answer or file.
        private static string CheckExamWrite(string action, JObject jo, ExamTaskContext ctx, int uid)
        {
            string Val(string name) => jo.Properties().FirstOrDefault(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase))?.Value?.ToString() ?? "";

            if (string.Equals(action, "_MgtUpdateAnswers", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(action, "_SetExamDefaultScores", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(action, "_MgtUpdateLMC", StringComparison.OrdinalIgnoreCase))
            {
                var ok = DB.GetDB("select top 1 1 as x from a_aMgtExamBody where ExamID = @examid and LineID = @lineid and Active = 1", uid,
                    new JObject { ["examid"] = ctx.ExamID, ["lineid"] = Val("lineid") }.ToString());
                return ok.Rows.Count > 0 && !ok.Columns.Contains("err") ? null : "line is not on this exam";
            }

            if (string.Equals(action, "_MgtUpdateAnswer", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(action, "_MgtArchiveAnswer", StringComparison.OrdinalIgnoreCase))
            {
                // The answer must be on this exam (via its line's element) and company,
                // and written by the caller's own company — the same "isMine" rule the
                // viewer uses to show Edit at all.
                var ok = DB.GetDB(
                    "select top 1 1 as x from a_aMgtExamAnswers a " +
                    "where a.AnswerID = @answerid and a.xCID = @xcid and a.Active = 1 " +
                    "and dbo.mycid(a.uid) = dbo.mycid(@uid) " +
                    "and a.ElemID in (" +
                    "  select le.ElemID from a_aMgtExamLineElems le join a_aMgtExamBody b on b.LineID = le.LineID and b.ExamID = @examid and b.Active = 1 " +
                    "  union select he.ElemID from a_aMgtExamHeatmapElems he join a_aMgtExamBody b on b.LineID = he.LineID and b.ExamID = @examid and b.Active = 1)",
                    uid, new JObject { ["answerid"] = Val("answerid"), ["xcid"] = ctx.ExamCID, ["examid"] = ctx.ExamID }.ToString());
                return ok.Rows.Count > 0 && !ok.Columns.Contains("err") ? null : "answer is not this exam's, or not your company's";
            }

            if (string.Equals(action, "_MgtDeleteFormDoc", StringComparison.OrdinalIgnoreCase))
            {
                var ok = DB.GetDB(
                    "select top 1 1 as x from a_aMGTExamDocs where FID = @fid and ExamID = @examid and xCID = @xcid and UID = @uid and Active = 1",
                    uid, new JObject { ["fid"] = Math.Abs(int.TryParse(Val("fid"), out var f) ? f : 0), ["examid"] = ctx.ExamID, ["xcid"] = ctx.ExamCID }.ToString());
                return ok.Rows.Count > 0 && !ok.Columns.Contains("err") ? null : "document is not your upload on this exam";
            }

            return null;
        }

        private static void MarkExamStarted(int messageItemId, int uid)
        {
            DB.GetDB("exec MBX_MarkExamTaskStarted @uid, @messageItemId", uid, "{\"messageItemId\":" + messageItemId + "}");
        }
    }
}
