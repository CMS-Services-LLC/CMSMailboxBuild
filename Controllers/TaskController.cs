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
    }
}
