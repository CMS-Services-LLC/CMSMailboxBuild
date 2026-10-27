using System;
using System.Collections.Generic;
using System.Data;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
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
    //   2. is on the allowlist for the caller's role (no heatmap report, PDF, zip or
    //      snapshots for either; scoring writes for the Assigner only);
    //   3. is pinned to the task: any examid must be the task's, any xcid becomes the
    //      examined company; answer edits/archives must be the task exam's answers written
    //      by the caller's company; deletes must be the caller's own upload on that exam;
    //      CMS-file attaches are the caller's own cached files for the examined company;
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
            "_MGTUpdateLastView",
            // Exam Workflow (CMS SharedSQLWithClaude/FEATURE_ExamWorkflow). Each proc checks the
            // caller itself (1518 network + AccessTreeDown / own company) and is pinned to the
            // task's examid/xcid below. _MgtGetWorkflowStatus can create + back-fill the
            // workflow on first open, the same as opening the exam in CMSNEO.
            "_MgtGetWorkflowStatus", "_MgtGetWorkflow", "_MgtGetWorkflowRecentRemoval", "_MgtGetWorkflowRecipients",
            // Document request "+" > From CMS: the caller's own CMS files for the examined
            // company. Only while the task can still change, and the file cache is rebuilt
            // first (see ExamAdHoc).
            "_MGTGetCMSFiles"
        };

        // Content writes: require CanWrite; the assignee's mark the task started.
        private static readonly HashSet<string> ExamWriteActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "_MgtUpdateAnswers", "_MgtUpdateAnswer", "_MgtArchiveAnswer", "_MgtDeleteFormDoc",
            "_MGTExamAttachCMSDoc"
        };

        // Management view only (scoring): the Assigner role.
        private static readonly HashSet<string> ExamAssignerWriteActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "_SetExamDefaultScores", "_MgtUpdateLMC",
            // The one-hour "remove from the Workflow" answer — management side only (the proc
            // re-checks that too); the action must be on this task's exam (CheckExamWrite).
            "_MgtWorkflowRemoveAction"
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

            if (string.Equals(action, "_MGTGetCMSFiles", StringComparison.OrdinalIgnoreCase))
            {
                if (!ctx.CanWrite)
                {
                    LogAccess(messageItemId, uid, "Denied", "exam: task is " + ctx.TaskStatus + ", no CMS file picker");
                    return Content("[]");
                }
                // NEO_MGTGetCMSFiles reads the caller's CMS file cache, which CMSNEO only
                // rebuilds when they open Documents there, so a mailbox user's may be empty
                // or old. Rebuild it the same way Documents does.
                DB.GetDB("exec NEO_GetFiles8 @uid, 1", uid);
            }

            string strParams = "";
            foreach (var key in jo) strParams += ", @" + key.Key;
            var dat = DB.GetDB("exec NEO" + action + " @uid" + strParams, uid, jo.ToString(Formatting.None));

            if (isWrite && !ctx.IsAssigner && !dat.Columns.Contains("err") &&
                (string.Equals(action, "_MgtUpdateAnswers", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(action, "_MgtUpdateAnswer", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(action, "_MGTExamAttachCMSDoc", StringComparison.OrdinalIgnoreCase)))
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
                if (!IsDocRequestOnExam(jo["lineid"]?.ToString() ?? "", jo["docreqid"]?.ToString() ?? "", ctx, uid))
                    why = "document request is not on this exam";
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

            if (string.Equals(action, "_MGTExamAttachCMSDoc", StringComparison.OrdinalIgnoreCase))
            {
                // Attached as the caller themself (the proc would otherwise act as any xuid),
                // into a document request on this exam, and only files the picker offered:
                // the caller's own cached CMS files for the examined company.
                // Values are set in place: the exec binds parameters by position (key order).
                JProperty Prop(string name) => jo.Properties().FirstOrDefault(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));
                if (Prop("xuid") == null || Prop("FIDS") == null) return "missing xuid or FIDS";
                Prop("xuid").Value = 0;
                if (!IsDocRequestOnExam(Val("lineid"), Val("docreqid"), ctx, uid)) return "document request is not on this exam";

                var fids = Val("FIDS").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .Select(s => int.TryParse(s, out var n) ? n : -1).Distinct().ToList();
                // Dynamic Report files have negative FIDs; the mailbox can't open those (exam-viewer.html).
                if (fids.Count == 0 || fids.Any(n => n <= 0)) return "no files selected, or a Dynamic Report file (not supported here)";

                var ok = DB.GetDB(
                    "select count(distinct f.FID) as n from NEO_MYFilesMar2026 f " +
                    "join (select try_cast(value as int) FID from string_split(@fids, ',')) x on x.FID = f.FID " +
                    "where f.CacheUID = @uid and f.FileCID = @xcid and f.FdrID > 0 and f.Folder <> '_archive'",
                    uid, new JObject { ["fids"] = string.Join(",", fids), ["xcid"] = ctx.ExamCID }.ToString());
                bool all = ok.Rows.Count > 0 && !ok.Columns.Contains("err") && Convert.ToInt32(ok.Rows[0]["n"]) == fids.Count;
                if (!all) return "a selected file is not one of your CMS files for the examined company";
                Prop("FIDS").Value = string.Join(",", fids);
                return null;
            }

            if (string.Equals(action, "_MgtWorkflowRemoveAction", StringComparison.OrdinalIgnoreCase))
            {
                var ok = DB.GetDB(
                    "select top 1 1 as x from a_aMgtExamWorkflowAction x " +
                    "join a_aMgtExamWorkflow w on w.WorkflowID = x.WorkflowID and w.Active = 1 " +
                    "where x.ActionID = @actionid and w.ExamID = @examid and w.xCID = @xcid",
                    uid, new JObject { ["actionid"] = int.TryParse(Val("actionid"), out var a) ? a : 0, ["examid"] = ctx.ExamID, ["xcid"] = ctx.ExamCID }.ToString());
                return ok.Rows.Count > 0 && !ok.Columns.Contains("err") ? null : "workflow action is not on this exam";
            }

            return null;
        }

        private static bool IsDocRequestOnExam(string lineid, string docreqid, ExamTaskContext ctx, int uid)
        {
            var dr = DB.GetDB(
                "select top 1 1 as x from a_aMGTExamDocRequest r " +
                "join a_aMgtExamBody b on b.LineID = r.LineID and b.ExamID = @examid and b.Active = 1 " +
                "where r.LineID = @lineid and r.DocReqID = @docreqid and r.Active = 1", uid,
                new JObject { ["examid"] = ctx.ExamID, ["lineid"] = lineid, ["docreqid"] = docreqid }.ToString());
            return dr.Rows.Count > 0 && !dr.Columns.Contains("err");
        }

        // ---- Exam Workflow report (PDF) -------------------------------------------------
        // The copied viewer's Workflow tab downloads or sends the landscape PDF report. It is
        // built by CMSNEO (main/MailboxWorkflowPdf: one GemBox, and its license, stays there),
        // as THIS user with a freshly minted one-off token, same as the DR and IA PDF proxies.
        // Both routes take strjson { examId, xcid, pendingOnly[, recipients, body] } and pin
        // the exam to the task (any other examid is refused; xcid becomes the examined company).

        [HttpPost("exam/{messageItemId:int}/workflow/pdf")]
        public async Task<IActionResult> ExamWorkflowPdf(int messageItemId, [FromForm] string strjson)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            var ctx = ResolveExamTask(messageItemId, uid);
            if (ctx == null) return NotFound();

            var jo = string.IsNullOrEmpty(strjson) ? new JObject() : JObject.Parse(strjson);
            if (!WorkflowExamMatches(jo, ctx)) { LogAccess(messageItemId, uid, "Denied", "exam workflow pdf: examid is not the task's exam"); return NotFound(); }

            var pdf = await FetchWorkflowPdf(uid, ctx, jo["pendingOnly"]?.ToObject<bool?>() ?? false);
            if (pdf == null) { LogAccess(messageItemId, uid, "Error", "exam workflow pdf: CMSNEO did not return it"); return NotFound(); }

            LogAccess(messageItemId, uid, "Served", "exam workflow pdf");
            return File(pdf.Value.Bytes, "application/pdf", pdf.Value.FileName);
        }

        [HttpPost("exam/{messageItemId:int}/workflow/send")]
        public async Task<IActionResult> ExamWorkflowSend(int messageItemId, [FromForm] string strjson)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            var ctx = ResolveExamTask(messageItemId, uid);
            if (ctx == null) return Content(new JObject { ["status"] = "not_found" }.ToString(), "application/json");

            var jo = string.IsNullOrEmpty(strjson) ? new JObject() : JObject.Parse(strjson);
            ContentResult St(string s) => Content(new JObject { ["status"] = s }.ToString(), "application/json");
            if (!WorkflowExamMatches(jo, ctx)) { LogAccess(messageItemId, uid, "Denied", "exam workflow send: examid is not the task's exam"); return St("forbidden"); }

            var requested = (jo["recipients"]?.ToObject<int[]>() ?? new int[0]).Distinct().ToArray();
            if (requested.Length == 0) return St("bad_request");

            // exam participants only — the same list the picker showed (NEO_MgtGetWorkflowRecipients)
            var allowed = new HashSet<int>(DB.GetDB("exec NEO_MgtGetWorkflowRecipients @uid, @examid, @xcid", uid,
                    new JObject { ["examid"] = ctx.ExamID, ["xcid"] = ctx.ExamCID }.ToString())
                .Rows.Cast<DataRow>().Where(r => r.Table.Columns.Contains("UID")).Select(r => Convert.ToInt32(r["UID"])));
            if (requested.Any(r => !allowed.Contains(r))) { LogAccess(messageItemId, uid, "Denied", "exam workflow send: recipient not an exam participant"); return St("forbidden"); }

            var pdf = await FetchWorkflowPdf(uid, ctx, jo["pendingOnly"]?.ToObject<bool?>() ?? false);
            if (pdf == null) { LogAccess(messageItemId, uid, "Error", "exam workflow send: CMSNEO did not return the PDF"); return St("proxy_failed"); }

            string note = (jo["body"]?.ToString() ?? "").Trim();
            string subject = "Exam Workflow: " + ctx.ExamName + (ctx.ExamCompany != "" ? " (" + ctx.ExamCompany + ")" : "");
            if (subject.Length > 255) subject = subject.Substring(0, 255);
            var msg = DB.GetDB("exec MBX_SendMessage @uid, @subject, @body", uid,
                new JObject { ["subject"] = subject, ["body"] = (note != "" ? note + "\n\n" : "") + "The exam workflow report is attached as a PDF." }.ToString());
            if (msg.Rows.Count == 0 || msg.Columns.Contains("err")) return St("error");
            int messageId = (int)decimal.Parse(msg.Rows[0]["MessageID"].ToString());

            DB.GetDB("exec MBX_AddRecipients @messageId, @recipientUIDsCSV", uid,
                new JObject { ["messageId"] = messageId, ["recipientUIDsCSV"] = string.Join(",", requested) }.ToString());

            // Binary parameter: DB.GetDB can't pass bytes (same as ComposeController.AddAttachment).
            var att = new DataTable();
            using (var da = new SqlDataAdapter("exec MBX_AddAttachment @uid, @messageId, @fileName, @contentType, @bytes", DB.ConnectionString))
            {
                da.SelectCommand.CommandTimeout = 180;
                da.SelectCommand.Parameters.AddWithValue("@uid", uid);
                da.SelectCommand.Parameters.AddWithValue("@messageId", messageId);
                da.SelectCommand.Parameters.AddWithValue("@fileName", pdf.Value.FileName);
                da.SelectCommand.Parameters.AddWithValue("@contentType", "application/pdf");
                da.SelectCommand.Parameters.Add("@bytes", SqlDbType.VarBinary, -1).Value = pdf.Value.Bytes;
                try { da.Fill(att); } catch { return St("error"); }
            }
            if (att.Rows.Count == 0 || att.Columns.Contains("err")) return St("error");

            ComposeController.NotifyRecipients(uid, messageId);
            LogAccess(messageItemId, uid, "Served", "exam workflow pdf sent as message " + messageId);
            return Content(new JObject { ["status"] = "ok", ["messageId"] = messageId }.ToString(), "application/json");
        }

        private static bool WorkflowExamMatches(JObject jo, ExamTaskContext ctx)
        {
            string examId = jo["examId"]?.ToString() ?? "";
            return string.Equals(examId, ctx.ExamID, StringComparison.OrdinalIgnoreCase);
        }

        private async Task<(byte[] Bytes, string FileName)?> FetchWorkflowPdf(int uid, ExamTaskContext ctx, bool pendingOnly)
        {
            if (string.IsNullOrEmpty(DB.CmsUrl)) { _logger.LogWarning("exam workflow pdf: AppSettings:CmsUrl is not set"); return null; }

            var mint = DB.GetDB("exec NEO_GetUserToken @uid", uid);
            string freshToken = (mint.Rows.Count > 0 && mint.Columns.Contains("Token")) ? mint.Rows[0]["Token"].ToString() : null;
            if (string.IsNullOrEmpty(freshToken)) { _logger.LogWarning("exam workflow pdf: NEO_GetUserToken returned no token"); return null; }

            var client = _httpClientFactory.CreateClient("CmsProxy");
            string url = DB.CmsUrl.TrimEnd('/') + "/main/MailboxWorkflowPdf?examId=" + Uri.EscapeDataString(ctx.ExamID) +
                "&xcid=" + ctx.ExamCID + "&pendingOnly=" + (pendingOnly ? "true" : "false") +
                "&token=" + Uri.EscapeDataString(freshToken);

            HttpResponseMessage resp;
            try { resp = await client.GetAsync(url); }
            catch (Exception ex) { _logger.LogWarning("exam workflow pdf: request to CMSNEO threw {Reason}", DescribeException(ex)); return null; }
            if (!resp.IsSuccessStatusCode) { _logger.LogWarning("exam workflow pdf: CMSNEO responded {Status}", (int)resp.StatusCode); return null; }

            var bytes = await resp.Content.ReadAsByteArrayAsync();
            string fileName = resp.Content.Headers.ContentDisposition?.FileNameStar ?? resp.Content.Headers.ContentDisposition?.FileName?.Trim('"');
            if (string.IsNullOrEmpty(fileName)) fileName = "Workflow.pdf";
            return (bytes, fileName);
        }

        private static void MarkExamStarted(int messageItemId, int uid)
        {
            DB.GetDB("exec MBX_MarkExamTaskStarted @uid, @messageItemId", uid, "{\"messageItemId\":" + messageItemId + "}");
        }
    }
}
