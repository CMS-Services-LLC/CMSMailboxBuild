using Microsoft.AspNetCore.Mvc;
using Newtonsoft.Json.Linq;

namespace CMSMailbox.Controllers
{
    // Task actions that apply to every task type. Currently just the optional review
    // step (sql/009): when tasks were sent with "Require my review", a finished task
    // shows Pending Review until its assigner marks it Completed here (from the Sent
    // folder). MBX_ReviewTask checks it's the task's own assigner, that review is
    // required and not yet done, and that the assignee has actually finished.
    public class TaskController : MailboxControllerBase
    {
        [HttpPost("item/{messageItemId:int}/task/review")]
        public IActionResult Review(int messageItemId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

            var dat = DB.GetDB("exec MBX_ReviewTask @uid, @messageItemId", uid, "{\"messageItemId\":" + messageItemId + "}");
            bool ok = dat.Rows.Count > 0 && !dat.Columns.Contains("err");

            DB.GetDB("exec MBX_LogAccess @messageItemId, @byUid, @result, @detail", uid,
                new JObject
                {
                    ["messageItemId"] = messageItemId,
                    ["byUid"] = uid,
                    ["result"] = ok ? "Served" : "Denied",
                    ["detail"] = ok ? "task marked completed (review)" : "task review refused: " + (dat.Columns.Contains("err") ? dat.Rows[0]["err"] : "no result")
                }.ToString());

            return ok ? Ok() : NotFound();
        }

        // Assignee-side sharing (sql/028): whoever was assigned a task shares it with colleagues in
        // their own company who hold the task's permission. The procs check the caller is the
        // task's assignee and the colleague is a current candidate. (The assigner shares from
        // CMS's Track Assigned Tasks.)
        [HttpGet("task/{taskId:int}/shares")]
        public IActionResult Shares(int taskId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

            var p = new JObject { ["taskId"] = taskId, ["side"] = "assignee" }.ToString();
            var shares = DB.GetDB("exec MBX_GetTaskShares @uid, @taskId, @side", uid, p);
            if (shares.Columns.Contains("err")) return NotFound();
            var candidates = DB.GetDB("exec MBX_GetTaskShareCandidates @uid, @taskId, @side", uid, p);
            if (candidates.Columns.Contains("err")) return NotFound();

            return Ok(new { shares = JArray.FromObject(shares), candidates = JArray.FromObject(candidates) });
        }

        [HttpPost("task/{taskId:int}/share")]
        public IActionResult Share(int taskId, [FromBody] ShareRequest req)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            string access = req?.Access ?? "";
            if (access != "manage" && access != "read" && access != "none") return BadRequest();

            var dat = DB.GetDB("exec MBX_SetTaskShare @uid, @taskId, @shareUid, @access, @side", uid,
                new JObject { ["taskId"] = taskId, ["shareUid"] = req.ShareUid, ["access"] = access, ["side"] = "assignee" }.ToString());
            if (dat.Rows.Count == 0) return NotFound();
            if (dat.Columns.Contains("err")) return Ok(new { status = dat.Rows[0]["err"].ToString() });
            return Ok(new { status = "ok" });
        }
    }

    public class ShareRequest
    {
        public int ShareUid { get; set; }
        public string Access { get; set; }
    }
}
