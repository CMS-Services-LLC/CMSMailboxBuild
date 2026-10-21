using System;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using Newtonsoft.Json.Linq;

namespace CMSMailbox.Controllers
{
    // Dynamic Report tasks (sql/008, WizardAssignments_Plan.md Phase 2). The assignee
    // downloads the Excel template the assigner attached and uploads it back filled in.
    //
    // Only the template download is served here. The upload is passed straight on to
    // CMSNEO's main/MailboxDRTaskSubmit, which parses it with the same GemBox read the
    // Dynamic Reports page uses, checks the headers against the template, inserts the
    // report as this user, and completes the task. That keeps one Excel parser (and
    // GemBox's license) in CMSNEO only. The outbound call carries a freshly minted
    // one-off token for THIS user, the same way GetIAPDF's proxy does, and CMSNEO
    // re-checks the task and the user's Dynamic Reports permission itself.
    public class DRTaskController : MailboxControllerBase
    {
        private readonly IHttpClientFactory _httpClientFactory;
        private readonly ILogger<DRTaskController> _logger;

        public DRTaskController(IHttpClientFactory httpClientFactory, ILogger<DRTaskController> logger)
        {
            _httpClientFactory = httpClientFactory;
            _logger = logger;
        }

        [HttpGet("item/{messageItemId:int}/drtask/template")]
        public IActionResult Template(int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

            var task = DB.GetDB("exec MBX_GetDRTask @uid, @messageItemId", uid, "{\"messageItemId\":" + messageItemId + "}");
            if (task.Rows.Count == 0 || task.Columns.Contains("err") || !(task.Rows[0]["TemplateBytes"] is byte[] bytes))
            {
                LogAccess(messageItemId, uid, "Denied", "DR template: no task for this user");
                return NotFound();
            }

            LogAccess(messageItemId, uid, "Served", "DR template");
            string fileName = task.Rows[0]["TemplateFileName"]?.ToString();
            return File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                string.IsNullOrEmpty(fileName) ? "template.xlsx" : fileName);
        }

        // Returns CMSNEO's JSON result as-is ({status, ...}); the page turns the status
        // into words. "proxy_failed" = CMSNEO couldn't be reached at all.
        [HttpPost("item/{messageItemId:int}/drtask/submit")]
        [DisableRequestSizeLimit]
        public async Task<IActionResult> Submit(int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

            var task = DB.GetDB("exec MBX_GetDRTask @uid, @messageItemId", uid, "{\"messageItemId\":" + messageItemId + "}");
            if (task.Rows.Count == 0 || task.Columns.Contains("err"))
            {
                LogAccess(messageItemId, uid, "Denied", "DR submit: no task for this user");
                return NotFound();
            }
            if (task.Rows[0]["Status"].ToString() != "Open") return StatusJson("already_completed");
            if (Request.Form.Files.Count == 0) return StatusJson("file_required");
            if (string.IsNullOrEmpty(DB.CmsUrl)) return ProxyFailed(messageItemId, uid, "AppSettings:CmsUrl is not set");

            var mint = DB.GetDB("exec NEO_GetUserToken @uid", uid);
            string freshToken = (mint.Rows.Count > 0 && mint.Columns.Contains("Token")) ? mint.Rows[0]["Token"].ToString() : null;
            if (string.IsNullOrEmpty(freshToken)) return ProxyFailed(messageItemId, uid, "NEO_GetUserToken returned no token");

            var file = Request.Form.Files[0];
            byte[] bytes;
            using (var ms = new MemoryStream()) { file.CopyTo(ms); bytes = ms.ToArray(); }

            var content = new MultipartFormDataContent();
            content.Add(new ByteArrayContent(bytes), "file", file.FileName);

            var client = _httpClientFactory.CreateClient("CmsProxy");
            string url = DB.CmsUrl.TrimEnd('/') + "/main/MailboxDRTaskSubmit?messageItemId=" + messageItemId +
                "&token=" + Uri.EscapeDataString(freshToken);

            HttpResponseMessage resp;
            try { resp = await client.PostAsync(url, content); }
            catch (Exception ex) { return ProxyFailed(messageItemId, uid, "request to CMSNEO threw " + ex.GetBaseException().Message); }

            if (!resp.IsSuccessStatusCode) return ProxyFailed(messageItemId, uid, "CMSNEO responded " + (int)resp.StatusCode);

            string result = await resp.Content.ReadAsStringAsync();
            string status = "";
            try { status = JObject.Parse(result)["status"]?.ToString() ?? ""; } catch { }
            LogAccess(messageItemId, uid, status == "ok" ? "Served" : "Error", "DR submit: " + status);

            return Content(result, "application/json");
        }

        private IActionResult ProxyFailed(int messageItemId, int uid, string reason)
        {
            // Never the token or the outbound URL — the reasons passed in don't contain
            // either, so they go in MBX_AccessLog too, where they're easy to look up.
            _logger.LogWarning("DR submit proxy failed: {Reason}", reason);
            LogAccess(messageItemId, uid, "Error", "DR submit proxy failed: " + reason);
            return StatusJson("proxy_failed");
        }

        private ContentResult StatusJson(string status) =>
            Content(new JObject { ["status"] = status }.ToString(), "application/json");

        private static void LogAccess(int messageItemId, int uid, string result, string detail)
        {
            DB.GetDB("exec MBX_LogAccess @messageItemId, @byUid, @result, @detail", uid,
                new JObject { ["messageItemId"] = messageItemId, ["byUid"] = uid, ["result"] = result, ["detail"] = detail ?? "" }.ToString());
        }
    }
}
