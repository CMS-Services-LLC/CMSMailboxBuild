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
    // Serves the "port-by-copy" IA record viewer: ia-viewer.html plus CMSNEO's own
    // InteractiveForm.js/global.js/etc (copied verbatim into wwwroot/js except two
    // small, documented adaptations — see the comments in those files) run unmodified
    // against the endpoints below instead of CMS's own main/adHoc.
    //
    // Security model: every action here re-derives (MainID, FormID) itself — from the
    // MessageItemID the client claims to be acting on for main/adHoc, or from the
    // MainID being requested for GetIAPDF — and re-runs BOTH gates before doing
    // anything else:
    //   Gate A: this recipient's own Team grant covers this specific FormID
    //           (NEO_NewSecurity's FormID column).
    //   Gate B: NEO_IAGetFormData actually returns rows for this uid/MainID/FormID
    //           (the real, confirmed-working per-record ACS check).
    // This repeats on every call, not just once at page load, so a recipient who loses
    // access mid-session is cut off on their very next request, not just their next login.
    public partial class IaViewerController : MailboxControllerBase
    {
        private readonly IHttpClientFactory _httpClientFactory;
        private readonly ILogger<IaViewerController> _logger;

        public IaViewerController(IHttpClientFactory httpClientFactory, ILogger<IaViewerController> logger)
        {
            _httpClientFactory = httpClientFactory;
            _logger = logger;
        }

        // Read-only IA actions the ported InteractiveForm.js's ViewDisp() render path
        // actually calls. Strict allowlist — anything else is refused regardless of
        // gate status, unlike CMS's own open main/adHoc dispatcher.
        private static readonly HashSet<string> ReadActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "_IAGetFormData", "_IAGetJoinRecord", "_IAGetFieldMGTData", "_IAGetMultiAnswers",
            "_IAGetDataBlanks", "_IAGetSetAprovalBy", "_IAGetFilesNotes", "_IAGetAddtlInfo",
            "_IAGetCIDs", "_IAGetAddtlInfoEmails", "_GetCleanFilename", "_GetUserToken",
            "_IAGetDataByMainID", "_GetGUIDs",
            // Record History. NEO_IAGetHistory2 only ACS-checks the header part, not the
            // field history itself, so AdHoc pins its mainid to this item's own record
            // (see PinnedToItemRecord).
            "_IAGetHistory"
        };

        // Actions whose procs don't check the caller's access to the record they're
        // given, so their mainid must be this message item's own record:
        //   _IAGetHistory      — NEO_IAGetHistory2 only ACS-checks the header part
        //   _IAGetJoinRecord, _IAGetMultiAnswers, _IAGetSetAprovalBy — no access check
        //                        at all (plan doc Section 6.2)
        // The ported viewer only ever calls these with the open record's own MainID
        // (ViewDisp; InteractiveForm.js's "applied record" path that would pass another
        // is dead code — triggeredID is hard-wired to null).
        private static readonly HashSet<string> PinnedToItemRecord = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "_IAGetHistory", "_IAGetJoinRecord", "_IAGetMultiAnswers", "_IAGetSetAprovalBy"
        };

        // Write actions — unblocked 2026-09-22 once every one of these procs' own
        // ownership checks was reviewed/fixed (plan doc Section 7.2). Gated here the
        // same as reads: cheap insurance where the proc itself also checks now, and
        // mandatory for _IADocAssign, whose SQL layer deliberately has no check of its
        // own ("anyone with access to the record" — this dispatcher's gate IS the
        // access control for that one).
        //
        // Deliberately NOT included: _IALoadFiles (needs a separate multipart-upload
        // endpoint CMS uses adHocAttach for — not built here yet), _IADeleteRecord /
        // _IADeleteRecords / _IACloneNotesAttachments (record-management actions, out
        // of scope for a reply-only mailbox viewer), _IARecallSignature / DocuSign
        // send-for-signature (separate integration, not reviewed for this app).
        private static readonly HashSet<string> WriteActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "_IASubmitDataByGen300_2", "_IALockRecord", "_IADelFileNote",
            "_IAAcceptAddtlInfo", "_IAGetSetSystemLinks", "_IADocAssign", "_IALoadNotes"
        };

        // New-record mode (a FormApplication task, sql/006): the item's ItemID is still
        // "0", so there is no record for Gate B to check yet. Only the calls the blank
        // ViewDisp(0, FormID) render and the first save actually need are allowed, and
        // AdHoc additionally pins mainid/formid/recordid/released (see
        // NewRecordParamsAllowed). After the first save the item points at the new
        // MainID and every later call takes the normal two-gate path above.
        private static readonly HashSet<string> NewRecordActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "_IAGetFormData", "_IAGetJoinRecord", "_IAGetFieldMGTData", "_IAGetMultiAnswers",
            "_IAGetDataBlanks", "_IAGetSetAprovalBy", "_IAGetCIDs", "_GetCleanFilename", "_GetGUIDs",
            "_IASubmitDataByGen300_2"
        };

        [HttpGet("item/{messageItemId:int}/bootstrap")]
        public IActionResult Bootstrap(int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

            // A record that hasn't been released ("Save for Use", DTReleased is null) is
            // only viewable by the company that created it — CMS's own report proc hides
            // it from everyone else, even upstream management companies whose ACS the
            // gates below would accept. Checked first so those viewers get a clear
            // message instead of a viewer that fails to render.
            if (IsUnreleasedForOtherCompany(messageItemId, uid))
                return StatusCode(403, new { reason = "unreleased" });

            var ctx = ResolveAndGateByMessageItem(messageItemId, uid);
            if (ctx == null) return NotFound();

            var creds = DB.GetDB("exec NEO_GetMGTCID @uid", uid);
            var security = DB.GetDB("exec NEO_NewSecurity @uid", uid);

            // No report row exists for a record that hasn't been created yet — and
            // NEO_IAGETALLDATA260903 with MainID 0 means "no single-record filter",
            // so it must not be called here.
            if (ctx.IsNewRecord)
            {
                return Ok(new
                {
                    ok = true,
                    newRecord = true,
                    mainId = 0,
                    formId = ctx.FormId,
                    reportRaw = "[]",
                    myCID = creds.Rows.Count > 0 ? creds.Rows[0]["MyCID"] : null,
                    mgtCID = creds.Rows.Count > 0 ? creds.Rows[0]["MgtCID"] : null,
                    isMGT = creds.Rows.Count > 0 && creds.Rows[0]["isMGT"] != DBNull.Value && Convert.ToInt32(creds.Rows[0]["isMGT"]) == 1,
                    myUID = uid,
                    security = JsonConvert.SerializeObject(security)
                });
            }

            // ViewDispGO reads several fields (Application_Type, hasDoc, strMainID, its
            // own echoed FormID, ...) off the "js" object InteractiveForm.js's ViewDisp()
            // builds by matching jsNeo.jsALL against a report-grid row — normally loaded
            // by CMS's own list view via NEO_IAGETALLDATA260903 before ViewDisp() ever
            // runs. Those specific fields are NOT present in NEO_IAGetFormData's rows
            // (confirmed against InteractiveForm.js's own "excludeFields" list, ~line
            // 696, which pulls exactly this field set out of that report proc's pivoted
            // "Values"/"ShortNames" rows). This standalone viewer has no report grid, so
            // it calls the same report proc itself, scoped to just this one MainID
            // (GETCACHE=0 so it can't rely on report state we never built), and hands
            // the raw pivoted rows to the client to unpivot the same way ViewDisp()'s
            // own report-loading code already does.
            var reportRaw = DB.GetDB("exec NEO_IAGETALLDATA260903 @uid, @formid, @FilterID, @MainID, @GETCACHE", uid,
                "{\"formid\":\"" + ctx.FormId + "\",\"FilterID\":0,\"MainID\":" + ctx.MainId + ",\"GETCACHE\":0}");

            return Ok(new
            {
                ok = true,
                mainId = ctx.MainId,
                formId = ctx.FormId,
                reportRaw = JsonConvert.SerializeObject(reportRaw),
                myCID = creds.Rows.Count > 0 ? creds.Rows[0]["MyCID"] : null,
                mgtCID = creds.Rows.Count > 0 ? creds.Rows[0]["MgtCID"] : null,
                isMGT = creds.Rows.Count > 0 && creds.Rows[0]["isMGT"] != DBNull.Value && Convert.ToInt32(creds.Rows[0]["isMGT"]) == 1,
                myUID = uid,
                security = JsonConvert.SerializeObject(security)
            });
        }

        // Mirrors CMS's own main/adHoc shape exactly (action/strjson/csrf form fields)
        // so the copied ajax.js/global.js work unmodified — "csrf" is accepted but
        // never checked; bearer JWT is this app's real auth. The one intentional
        // addition, "messageItemId", is injected by the patched newFormData() in the
        // copied global.js (see that file) and is what lets this dispatcher re-derive
        // the record context itself instead of trusting the client's own mainid/
        // recordid fields.
        [HttpPost("main/adHoc")]
        public IActionResult AdHoc(string action, string strjson, string csrf, int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Content("[]");

            // The exam viewer's ported scripts post here too (same relative URL) —
            // ExamTask items are handled entirely by IaViewerController.Exam.cs.
            if (IsExamItem(messageItemId)) return ExamAdHoc(action, strjson, messageItemId, uid);

            var ctx = ResolveAndGateByMessageItem(messageItemId, uid);
            if (ctx == null) return Content("[]");

            bool allowed = ctx.IsNewRecord
                ? NewRecordActions.Contains(action ?? "")
                : ReadActions.Contains(action ?? "") || WriteActions.Contains(action ?? "");
            if (!allowed)
            {
                LogAccess(messageItemId, uid, "Denied", "action not on allowlist" + (ctx.IsNewRecord ? " (new-record mode): " : ": ") + action);
                return Content("[]");
            }

            var jo = string.IsNullOrEmpty(strjson) ? new JObject() : JObject.Parse(strjson);

            if (ctx.IsNewRecord)
            {
                string why = NewRecordParamsAllowed(action, jo, ctx);
                if (why != null)
                {
                    LogAccess(messageItemId, uid, "Denied", "new-record mode: " + why);
                    return Content("[]");
                }
                // Releasing isn't offered on an unsaved record in the UI (ViewDispGO
                // hides "Save for Use" when MainID is 0) — don't let it through here.
                if (jo["released"] != null) jo["released"] = 0;
                strjson = jo.ToString(Formatting.None);
            }
            else if (PinnedToItemRecord.Contains(action ?? ""))
            {
                var mainidProp = jo.Properties().FirstOrDefault(p => string.Equals(p.Name, "mainid", StringComparison.OrdinalIgnoreCase));
                if (mainidProp == null || mainidProp.Value?.ToString() != ctx.MainId.ToString())
                {
                    LogAccess(messageItemId, uid, "Denied", action + ": mainid is not this item's record");
                    return Content("[]");
                }
            }

            // ViewDisp() only ever calls this with an empty Fieldname (read mode) —
            // NEO_IAGetSetAprovalBy has an unguarded write branch when Fieldname is
            // non-empty (plan doc Section 6.2), so refuse that outright rather than
            // trust the client never to send one.
            if (string.Equals(action, "_IAGetSetAprovalBy", StringComparison.OrdinalIgnoreCase))
            {
                var fieldname = jo["Fieldname"]?.ToString() ?? "";
                if (fieldname != "")
                {
                    LogAccess(messageItemId, uid, "Denied", "_IAGetSetAprovalBy write branch blocked");
                    return Content("[]");
                }
            }

            string strParams = "";
            foreach (var key in jo) strParams += ", @" + key.Key;

            string sql = "exec NEO" + action + " @uid" + strParams;
            var dat = DB.GetDB(sql, uid, strjson ?? "");

            LogAccess(messageItemId, uid, "Served", action);

            // First save of a new-record task: the proc created the record and returned
            // its MainID. Link it to this item (the task stays open until the record is
            // released — see sql/007), so the item now opens through the normal
            // two-gate path.
            if (ctx.IsNewRecord && string.Equals(action, "_IASubmitDataByGen300_2", StringComparison.OrdinalIgnoreCase)
                && dat.Rows.Count > 0 && dat.Columns.Contains("MainID")
                && int.TryParse(dat.Rows[0]["MainID"]?.ToString(), out int newMainId) && newMainId > 0)
            {
                var linked = DB.GetDB("exec MBX_LinkFormTask @uid, @messageItemId, @mainId", uid,
                    "{\"messageItemId\":" + messageItemId + ",\"mainId\":" + newMainId + "}");
                LogAccess(messageItemId, uid, linked.Columns.Contains("err") ? "Error" : "Served",
                    linked.Columns.Contains("err") ? "task link failed: " + linked.Rows[0]["err"] : "task linked to MainID " + newMainId);
            }

            return Content(JsonConvert.SerializeObject(dat), "application/json");
        }

        // Returns null if this new-record-mode call is allowed, else the reason. The
        // record context is pinned server-side: no call may name an existing record
        // (any mainid must be 0), any formid must be the task's own form, and a save
        // must use a fresh recordid — one that doesn't already belong to a record,
        // which is what makes NEO_IASubmitDataByGen300_2 create a new one rather than
        // write into an existing record.
        private static string NewRecordParamsAllowed(string action, JObject jo, ItemContext ctx)
        {
            foreach (var p in jo.Properties())
            {
                string val = p.Value?.ToString() ?? "";
                if (string.Equals(p.Name, "mainid", StringComparison.OrdinalIgnoreCase) && val != "0" && val != "")
                    return "mainid must be 0";
                if (string.Equals(p.Name, "formid", StringComparison.OrdinalIgnoreCase) && val != "" &&
                    !string.Equals(val, ctx.FormId, StringComparison.OrdinalIgnoreCase))
                    return "formid is not the task's form";
            }

            if (string.Equals(action, "_IASubmitDataByGen300_2", StringComparison.OrdinalIgnoreCase))
            {
                string formId = jo["formid"]?.ToString() ?? "";
                string recordId = jo["recordid"]?.ToString() ?? "";
                if (!string.Equals(formId, ctx.FormId, StringComparison.OrdinalIgnoreCase)) return "save must name the task's form";
                if (!Guid.TryParse(recordId, out _)) return "save needs a new recordid";

                var existing = DB.GetDB("select top 1 1 as x from NEO_IAFormRecords where RecordID = @recordId", 0,
                    "{\"recordId\":\"" + recordId + "\"}");
                if (existing.Rows.Count > 0) return "recordid already belongs to a record";
            }

            return null;
        }

        // Mirrors CMS's own main/adHocAttach (HomeController.cs ~line 2496) for
        // file-uploading actions — a separate endpoint from main/adHoc because
        // DB.GetDB can't bind binary data (it JSON-round-trips every parameter
        // through .ToString()), so this builds its own SqlDataAdapter call the same
        // way CMS's adhocAttachFile() does. Restricted to _IALoadFiles only — a
        // strict allowlist of one, unlike CMS's fully generic version, consistent
        // with main/adHoc's own philosophy. Gated the same as every other action:
        // messageItemId is already carried automatically here since this call goes
        // through the patched newFormData()/getData(), unlike LoadGeneric300 or the
        // DownloadIA links, which needed an explicit client-side patch.
        [HttpPost("main/adHocAttach")]
        [DisableRequestSizeLimit]
        public IActionResult AdHocAttach(string action, string strjson, string csrf, int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Content("[]");

            if (IsExamItem(messageItemId)) return ExamAdHocAttach(action, strjson, messageItemId, uid);

            var ctx = ResolveAndGateByMessageItem(messageItemId, uid);
            if (ctx == null) return Content("[]");

            // Attachments need a saved record (the UI says so too for MainID 0).
            if (ctx.IsNewRecord) return Content("[]");

            if (!string.Equals(action, "_IALoadFiles", StringComparison.OrdinalIgnoreCase))
            {
                LogAccess(messageItemId, uid, "Denied", "adHocAttach action not on allowlist: " + action);
                return Content("[]");
            }

            var jo = string.IsNullOrEmpty(strjson) ? new JObject() : JObject.Parse(strjson);
            string rtn = "[]";

            if (Request.Form.Files.Count > 0)
            {
                foreach (var file in Request.Form.Files)
                {
                    byte[] filedata;
                    using (var ms = new MemoryStream())
                    {
                        file.CopyTo(ms);
                        filedata = ms.ToArray();
                    }

                    rtn = JsonConvert.SerializeObject(RunAttachSql(action, file.FileName, filedata, jo, uid));
                }
            }

            LogAccess(messageItemId, uid, "Served", action);
            return Content(rtn, "application/json");
        }

        // Positional-by-name the same way CMS's adhocAttachFile does: @filename and
        // @filedata come right after @uid, then the rest of strjson's keys — SQL
        // Server matches EXEC ... @paramName arguments to the proc's own declared
        // parameter names, not call-site order, so this only works because the
        // client's JSON keys already match NEO_IALoadFiles' real parameter names.
        private DataTable RunAttachSql(string action, string filename, byte[] filedata, JObject jo, int uid)
        {
            var dat = new DataTable();
            string strParams = "";
            foreach (var key in jo) strParams += ", @" + key.Key;

            string sql = "exec NEO" + action + " @uid, @filename, @filedata" + strParams;
            var da = new SqlDataAdapter(sql, DB.ConnectionString);
            da.SelectCommand.CommandTimeout = 180;
            da.SelectCommand.Parameters.AddWithValue("@uid", uid);
            da.SelectCommand.Parameters.AddWithValue("@filename", filename);
            da.SelectCommand.Parameters.AddWithValue("@filedata", filedata);
            foreach (var key in jo) da.SelectCommand.Parameters.AddWithValue("@" + key.Key, key.Value.ToString());

            try { da.Fill(dat); } catch { /* best-effort, matches CMS's own adhocAttachFile */ }
            return dat;
        }

        // Proxies CMSNEO's own PDF export rather than reimplementing GemBox/DocuSign
        // here. CMSMailbox re-verifies access itself (by MainID, since the ported
        // exportDoc() builds this iframe src without a messageItemId), then asks
        // CMSNEO to build the PDF using the RECIPIENT's own uid — never the sender's —
        // exactly as if that recipient had opened the record in CMSNEO directly.
        [HttpGet("GetIAPDF")]
        public async Task<IActionResult> GetIAPDF(int MainID, string filename, string token = "")
        {
            int uid = ResolveOneOffUid(token);
            if (uid == 0) return ProxyNotFound("GetIAPDF", "one-off token did not resolve to a user");

            string formId = LookupFormIdForMainId(uid, MainID);
            if (formId == null) return ProxyNotFound("GetIAPDF", "no MBX_MessageItem found for this MainID and user");
            if (!PassesGates(uid, MainID, formId)) return ProxyNotFound("GetIAPDF", "access gates failed");

            if (string.IsNullOrEmpty(DB.CmsUrl)) return ProxyNotFound("GetIAPDF", "AppSettings:CmsUrl is not set");

            // Mint a fresh one-off token for the outbound call rather than forwarding
            // the client-supplied one, in case NEO_GetUserToken tokens are single-use.
            var mint = DB.GetDB("exec NEO_GetUserToken @uid", uid);
            string freshToken = (mint.Rows.Count > 0 && mint.Columns.Contains("Token")) ? mint.Rows[0]["Token"].ToString() : null;
            if (string.IsNullOrEmpty(freshToken)) return ProxyNotFound("GetIAPDF", "NEO_GetUserToken returned no token");

            var client = _httpClientFactory.CreateClient("CmsProxy");
            string url = DB.CmsUrl.TrimEnd('/') + "/GetIAPDF?MainID=" + MainID +
                "&filename=" + Uri.EscapeDataString(filename ?? "") +
                "&token=" + Uri.EscapeDataString(freshToken);

            HttpResponseMessage resp;
            try { resp = await client.GetAsync(url); }
            catch (Exception ex) { return ProxyNotFound("GetIAPDF", "request to CMSNEO threw " + DescribeException(ex)); }

            if (!resp.IsSuccessStatusCode) return ProxyNotFound("GetIAPDF", "CMSNEO responded " + (int)resp.StatusCode);

            var bytes = await resp.Content.ReadAsByteArrayAsync();
            return File(bytes, "application/pdf");
        }

        // These two proxy routes used to return a bare 404 for every failure, which made
        // "which step failed" impossible to tell apart (bad token vs. gate vs. CmsUrl
        // vs. CMSNEO itself). The client still gets the same indistinguishable 404 —
        // only the server log gets the reason. Never log the token or the outbound URL.
        private IActionResult ProxyNotFound(string route, string reason)
        {
            _logger.LogWarning("{Route} -> 404: {Reason}", route, reason);
            return NotFound();
        }

        private static string DescribeException(Exception ex)
        {
            var inner = ex;
            while (inner.InnerException != null) inner = inner.InnerException;
            return ex.GetType().Name + (inner != ex ? " / " + inner.GetType().Name : "") + ": " + inner.Message;
        }

        // Proxies CMSNEO's own attachment viewer/download route the same way
        // GetIAPDF proxies the PDF export. Unlike MainID, an attachment's fid has no
        // natural-key lookup into MBX_MessageItem, so this is gated by messageItemId
        // instead (added explicitly by the ported FileViewer.js — see that file) —
        // proves the recipient currently has SOME gated-open IAFormRecord item, the
        // same trust boundary GetIAPDF relies on for its own one-off token mint.
        [HttpGet("DownloadIA")]
        public async Task<IActionResult> DownloadIA(string fid, int dl, string token, int messageItemId)
        {
            int uid = ResolveOneOffUid(token);
            if (uid == 0) return ProxyNotFound("DownloadIA", "one-off token did not resolve to a user");

            var ctx = ResolveAndGateByMessageItem(messageItemId, uid);
            if (ctx == null) return ProxyNotFound("DownloadIA", "access gates failed for this messageItemId");
            if (ctx.IsNewRecord) return ProxyNotFound("DownloadIA", "new-record task item has no attachments yet");

            if (string.IsNullOrEmpty(DB.CmsUrl)) return ProxyNotFound("DownloadIA", "AppSettings:CmsUrl is not set");

            var mint = DB.GetDB("exec NEO_GetUserToken @uid", uid);
            string freshToken = (mint.Rows.Count > 0 && mint.Columns.Contains("Token")) ? mint.Rows[0]["Token"].ToString() : null;
            if (string.IsNullOrEmpty(freshToken)) return ProxyNotFound("DownloadIA", "NEO_GetUserToken returned no token");

            var client = _httpClientFactory.CreateClient("CmsProxy");
            string url = DB.CmsUrl.TrimEnd('/') + "/DownloadIA?fid=" + Uri.EscapeDataString(fid ?? "") +
                "&dl=" + dl + "&token=" + Uri.EscapeDataString(freshToken);

            HttpResponseMessage resp;
            try { resp = await client.GetAsync(url); }
            catch (Exception ex) { return ProxyNotFound("DownloadIA", "request to CMSNEO threw " + DescribeException(ex)); }

            if (!resp.IsSuccessStatusCode) return ProxyNotFound("DownloadIA", "CMSNEO responded " + (int)resp.StatusCode);

            var bytes = await resp.Content.ReadAsByteArrayAsync();
            string contentType = resp.Content.Headers.ContentType?.ToString() ?? "application/octet-stream";
            return File(bytes, contentType);
        }

        // The ported SubmitRecord()'s save flow stages field changes into
        // NEO_GetGeneric300 via this endpoint BEFORE calling _IASubmitDataByGen300_2
        // through the gated main/adHoc dispatcher above — CMS's own HomeController.cs
        // has an identical LoadGeneric300 action (~line 5600) that this replicates.
        // This call is built directly (`new FormData()`, not newFormData()) by the
        // ported InteractiveForm.js, so it carries messageItemId via a small,
        // documented patch to that file rather than the shared helper.
        //
        // Staging alone doesn't write anything to the real record — that only
        // happens when _IASubmitDataByGen300_2 reads this back by (@uid, @type) and
        // applies NEOGen3AuthorizedFields' own per-CID field filter (the user's own
        // fix, see plan doc Section 7.2). Still gated the same as every other action
        // here, consistent with "cheap insurance even where the real check is
        // downstream."
        [HttpPost("LoadGeneric300")]
        public IActionResult LoadGeneric300(string strJson, string type, int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Content("[]");

            var ctx = ResolveAndGateByMessageItem(messageItemId, uid);
            if (ctx == null) return Content("[]");

            if (string.IsNullOrEmpty(strJson)) return Content("[]");
            var arr = JArray.Parse(strJson);
            if (arr.Count == 0) return Content("[]");

            var first = (JObject)arr[0];
            var hdrs = first.Properties().Select(p => p.Name.Replace("|", "").Replace("~", "")).ToList();
            var rows = new List<string> { string.Join("|", hdrs) };
            foreach (var item in arr)
            {
                var jo = (JObject)item;
                var cols = hdrs.Select(h => (jo[h]?.ToString() ?? "").Replace("|", "").Replace("~", ""));
                rows.Add(string.Join("|", cols));
            }

            var dat = DB.GetDB("exec NEO_GetGeneric300 @uid, @rows, @type", uid,
                JsonConvert.SerializeObject(new JObject
                {
                    ["rows"] = string.Join("~", rows),
                    ["type"] = type ?? ""
                }));

            return Content(JsonConvert.SerializeObject(dat), "application/json");
        }

        private class ItemContext { public int MainId; public string FormId; public bool IsNewRecord; }

        private ItemContext ResolveAndGateByMessageItem(int messageItemId, int uid)
        {
            var lookup = DB.GetDB(
                "select mi.ItemType, mi.ItemID, mi.FormID from MBX_MessageItem mi " +
                "join MBX_Recipient r on r.MessageID = mi.MessageID and r.ToUID = @uid " +
                "where mi.MessageItemID = @messageItemId",
                uid, "{\"messageItemId\":" + messageItemId + "}");

            if (lookup.Rows.Count == 0 || lookup.Columns.Contains("err") ||
                lookup.Rows[0]["ItemType"].ToString() != "IAFormRecord")
            {
                LogAccess(messageItemId, uid, "Denied", "not a recipient or not an IAFormRecord item");
                return null;
            }

            string formId = lookup.Rows[0]["FormID"]?.ToString();

            if (lookup.Rows[0]["ItemID"].ToString() == "0")
            {
                return ResolveNewRecordTask(messageItemId, uid, formId);
            }

            if (string.IsNullOrEmpty(formId) || !int.TryParse(lookup.Rows[0]["ItemID"].ToString(), out int mainId) || mainId <= 0)
            {
                LogAccess(messageItemId, uid, "Error", "missing/invalid FormID or MainID on IAFormRecord item");
                return null;
            }

            if (!PassesGates(uid, mainId, formId))
            {
                LogAccess(messageItemId, uid, "Denied", "failed Gate A/Gate B");
                return null;
            }

            return new ItemContext { MainId = mainId, FormId = formId };
        }

        // ItemID "0" = a FormApplication task not started yet. Allowed only while an
        // Open task on this item is assigned to this caller (MBX_GetOpenFormTask also
        // re-checks they're a recipient), and only with Gate A — the caller's own
        // Team grant for the form. There's no record yet, so no Gate B.
        private ItemContext ResolveNewRecordTask(int messageItemId, int uid, string itemFormId)
        {
            var task = DB.GetDB("exec MBX_GetOpenFormTask @uid, @messageItemId", uid,
                "{\"messageItemId\":" + messageItemId + "}");
            if (task.Rows.Count == 0 || task.Columns.Contains("err"))
            {
                LogAccess(messageItemId, uid, "Denied", "new-record item without an open task for this user");
                return null;
            }

            string formId = task.Rows[0]["FormID"]?.ToString();
            if (string.IsNullOrEmpty(formId) || !string.Equals(formId, itemFormId, StringComparison.OrdinalIgnoreCase))
            {
                LogAccess(messageItemId, uid, "Error", "task FormID missing or doesn't match the item");
                return null;
            }

            if (!PassesGateA(uid, formId))
            {
                LogAccess(messageItemId, uid, "Denied", "new-record task failed Gate A");
                return null;
            }

            return new ItemContext { MainId = 0, FormId = formId, IsNewRecord = true };
        }

        // Used only by GetIAPDF, which receives a MainID but no MessageItemID (the
        // ported exportDoc() builds that iframe src without one). ItemType+ItemID is
        // already a natural key into this recipient's own shared IA items, so this
        // re-derives the same FormID a messageItemId lookup would without needing one.
        private string LookupFormIdForMainId(int uid, int mainId)
        {
            var lookup = DB.GetDB(
                "select top 1 mi.FormID from MBX_MessageItem mi " +
                "join MBX_Recipient r on r.MessageID = mi.MessageID and r.ToUID = @uid " +
                "where mi.ItemType = 'IAFormRecord' and mi.ItemID = @mainId",
                uid, "{\"mainId\":\"" + mainId + "\"}");

            if (lookup.Rows.Count == 0 || lookup.Columns.Contains("err")) return null;
            return lookup.Rows[0]["FormID"]?.ToString();
        }

        private bool PassesGates(int uid, int mainId, string formId)
        {
            if (!PassesGateA(uid, formId)) return false;

            var formData = DB.GetDB("exec NEO_IAGetFormData @uid, @MainID, @FormID", uid,
                "{\"MainID\":" + mainId + ",\"FormID\":\"" + formId + "\"}");

            return formData.Rows.Count > 0 && !formData.Columns.Contains("err");
        }

        // True when this user is a recipient of this IAFormRecord item, the record is
        // active with DTReleased null, and the user's current company isn't the
        // record's own company (which can always see its unreleased records — that's
        // how the assignee gets back in to click Save for Use). Only refuses; it
        // never grants anything.
        private static bool IsUnreleasedForOtherCompany(int messageItemId, int uid)
        {
            var dat = DB.GetDB(
                "select top 1 1 as x " +
                "from MBX_MessageItem mi " +
                "join MBX_Recipient r on r.MessageID = mi.MessageID and r.ToUID = @uid " +
                "join NEO_IAFormRecords xfr on xfr.ID = try_cast(mi.ItemID as int) " +
                "join NEO_IAFormRecords fr on fr.RecordID = xfr.RecordID and fr.active = 1 " +
                "where mi.MessageItemID = @messageItemId and mi.ItemType = 'IAFormRecord' and mi.ItemID <> '0' " +
                "and fr.DTReleased is null and fr.CID <> dbo.mycid(@uid)",
                uid, "{\"messageItemId\":" + messageItemId + "}");

            return dat.Rows.Count > 0 && !dat.Columns.Contains("err");
        }

        // Gate A: this user's own Team grant covers this FormID (NEO_NewSecurity
        // returns one row per granted FormID).
        private static bool PassesGateA(int uid, string formId)
        {
            if (string.IsNullOrEmpty(formId)) return false;

            var security = DB.GetDB("exec NEO_NewSecurity @uid", uid);
            return security.Columns.Contains("FormID") &&
                security.Rows.Cast<DataRow>().Any(r => r["FormID"] != DBNull.Value && r["FormID"].ToString() == formId);
        }

        // Looks up the UID for a one-off token minted via NEO_GetUserToken — same
        // shared-table lookup CMS's own zUID() does — never a JWT decode.
        private int ResolveOneOffUid(string token)
        {
            if (string.IsNullOrEmpty(token)) return 0;
            var dat = DB.GetDB("exec NEO_GetUserToken @uid, @token", 0, "{\"token\":\"" + token + "\"}");
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err") || !dat.Columns.Contains("UID")) return 0;
            try { return Convert.ToInt32(dat.Rows[0]["UID"]); } catch { return 0; }
        }

        private static void LogAccess(int messageItemId, int uid, string result, string detail)
        {
            DB.GetDB("exec MBX_LogAccess @messageItemId, @byUid, @result, @detail", uid,
                "{\"messageItemId\":" + messageItemId + ",\"byUid\":" + uid +
                ",\"result\":\"" + result + "\",\"detail\":\"" + (detail ?? "").Replace("\"", "'") + "\"}");
        }
    }
}
