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
    // Phase 6 (sql/029): composing a new secure message in the mailbox, and file attachments on
    // messages and replies, separate from tasks.
    //
    // - A new message can go to anyone in the sender's CMS network (MBX_GetComposeRecipients);
    //   the recipient list is re-derived here on send, never taken from the page.
    // - Attachments are added by the message's own author right after sending (MBX_AddAttachment
    //   checks author + within the hour + at most 10). Size and type are checked here.
    // - Anyone who can read the message downloads them (MBX_CanReadMessage: author, recipient,
    //   or a colleague a task on it was shared with).
    // - New messages and replies email each recipient a link-only notification.
    public class ComposeController : MailboxControllerBase
    {
        public const long MaxAttachmentBytes = 25L * 1024 * 1024;
        public const int MaxAttachments = 10;

        // Allowed types, and the content type each is stored and served with. The browser's own
        // claim is ignored: a file served back with a type it chose (e.g. text/html) could run as
        // a page on this site.
        private static readonly Dictionary<string, string> AllowedTypes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            [".pdf"] = "application/pdf",
            [".doc"] = "application/msword",
            [".docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            [".xls"] = "application/vnd.ms-excel",
            [".xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            [".ppt"] = "application/vnd.ms-powerpoint",
            [".pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            [".png"] = "image/png",
            [".jpg"] = "image/jpeg",
            [".jpeg"] = "image/jpeg",
            [".gif"] = "image/gif",
            [".txt"] = "text/plain",
            [".csv"] = "text/csv",
            [".zip"] = "application/zip"
        };

        [HttpGet("inbox/compose-recipients")]
        public IActionResult ComposeRecipients()
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            return Ok(JsonConvert.SerializeObject(DB.GetDB("exec MBX_GetComposeRecipients @uid", uid)));
        }

        [HttpPost("inbox/compose")]
        public IActionResult Compose([FromBody] ComposeRequest req)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

            string subject = (req?.Subject ?? "").Trim();
            if (subject == "") return Ok(new { status = "subject_required" });
            if (subject.Length > 255) subject = subject.Substring(0, 255);
            var wanted = (req?.ToUIDs ?? new List<int>()).Distinct().ToList();
            if (wanted.Count == 0) return Ok(new { status = "recipients_required" });

            var allowed = new HashSet<int>(DB.GetDB("exec MBX_GetComposeRecipients @uid", uid).Rows
                .Cast<DataRow>().Select(r => Convert.ToInt32(r["UID"])));
            if (wanted.Any(w => !allowed.Contains(w))) return Ok(new { status = "recipient_not_allowed" });

            var msg = DB.GetDB("exec MBX_SendMessage @uid, @subject, @body", uid,
                new JObject { ["subject"] = subject, ["body"] = req.Body ?? "" }.ToString());
            if (msg.Rows.Count == 0 || msg.Columns.Contains("err")) return Ok(new { status = "error" });
            int messageId = (int)decimal.Parse(msg.Rows[0]["MessageID"].ToString());

            DB.GetDB("exec MBX_AddRecipients @messageId, @recipientUIDsCSV", uid,
                new JObject { ["messageId"] = messageId, ["recipientUIDsCSV"] = string.Join(",", wanted) }.ToString());

            NotifyRecipients(uid, messageId);
            return Ok(new { status = "ok", messageId });
        }

        // Link-only email to each recipient of a message the caller just sent (new or reply).
        // Best-effort: a failed email never fails the send.
        public static void NotifyRecipients(int uid, int messageId)
        {
            var dat = DB.GetDB("exec MBX_GetMessageRecipientEmails @uid, @messageId", uid,
                new JObject { ["messageId"] = messageId }.ToString());
            if (dat.Columns.Contains("err")) return;
            foreach (DataRow r in dat.Rows)
            {
                try
                {
                    string email = r["Email"]?.ToString();
                    if (string.IsNullOrEmpty(email)) continue;
                    Mail.SendNewMessageNotification(email, r["SenderName"]?.ToString(), r["SenderCompany"]?.ToString(), messageId);
                }
                catch { }
            }
        }

        [HttpPost("inbox/{messageId:int}/attachments")]
        [RequestSizeLimit(MaxAttachmentBytes + 1024 * 1024)]
        [RequestFormLimits(MultipartBodyLengthLimit = MaxAttachmentBytes + 1024 * 1024)]
        public IActionResult AddAttachment(int messageId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            if (Request.Form.Files.Count != 1) return Ok(new { status = "one_file_per_request" });

            var file = Request.Form.Files[0];
            string name = Path.GetFileName(file.FileName ?? "");
            if (name == "") return Ok(new { status = "bad_file" });
            if (!AllowedTypes.TryGetValue(Path.GetExtension(name), out string contentType)) return Ok(new { status = "type_not_allowed" });
            if (file.Length == 0) return Ok(new { status = "empty_file" });
            if (file.Length > MaxAttachmentBytes) return Ok(new { status = "too_large" });
            if (name.Length > 255) name = name.Substring(name.Length - 255);

            byte[] bytes;
            using (var ms = new MemoryStream()) { file.CopyTo(ms); bytes = ms.ToArray(); }

            // Binary parameter: DB.GetDB can't pass bytes (same as DRViewController.AddDoc).
            var dat = new DataTable();
            using (var da = new SqlDataAdapter("exec MBX_AddAttachment @uid, @messageId, @fileName, @contentType, @bytes", DB.ConnectionString))
            {
                da.SelectCommand.CommandTimeout = 180;
                da.SelectCommand.Parameters.AddWithValue("@uid", uid);
                da.SelectCommand.Parameters.AddWithValue("@messageId", messageId);
                da.SelectCommand.Parameters.AddWithValue("@fileName", name);
                da.SelectCommand.Parameters.AddWithValue("@contentType", contentType);
                da.SelectCommand.Parameters.Add("@bytes", SqlDbType.VarBinary, -1).Value = bytes;
                try { da.Fill(dat); } catch { return Ok(new { status = "error" }); }
            }
            if (dat.Rows.Count == 0) return Ok(new { status = "error" });
            if (dat.Columns.Contains("err")) return Ok(new { status = dat.Rows[0]["err"].ToString() });
            return Ok(new { status = "ok", attachmentId = dat.Rows[0]["AttachmentID"] });
        }

        [HttpGet("inbox/{messageId:int}/attachments")]
        public IActionResult ListAttachments(int messageId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            return Ok(JsonConvert.SerializeObject(DB.GetDB("exec MBX_GetAttachments @uid, @messageId", uid,
                new JObject { ["messageId"] = messageId }.ToString())));
        }

        // The whole conversation this message is part of (sql/030): every message in the thread
        // the caller can read, oldest first, each with its attachments.
        [HttpGet("inbox/{messageId:int}/thread")]
        public IActionResult Thread(int messageId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();

            var ds = DB.GetDBSet("exec MBX_GetThread @uid, @messageId", uid,
                new JObject { ["messageId"] = messageId }.ToString());
            if (ds.Tables.Count == 0 || ds.Tables[0].Rows.Count == 0) return NotFound();

            return Ok(new
            {
                messages = JsonConvert.SerializeObject(ds.Tables[0]),
                attachments = ds.Tables.Count > 1 ? JsonConvert.SerializeObject(ds.Tables[1]) : "[]"
            });
        }

        [HttpGet("attachment/{attachmentId:int}")]
        public IActionResult Download(int attachmentId)
        {
            int uid = CurrentUID();
            if (uid == 0) return Unauthorized();
            var dat = DB.GetDB("exec MBX_GetAttachment @uid, @attachmentId", uid,
                new JObject { ["attachmentId"] = attachmentId }.ToString());
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err") || dat.Rows[0]["Bytes"] == DBNull.Value) return NotFound();

            // Always a download (Content-Disposition: attachment), typed from the extension.
            string fileName = dat.Rows[0]["FileName"]?.ToString() ?? "attachment";
            string type = AllowedTypes.TryGetValue(Path.GetExtension(fileName), out string t) ? t : "application/octet-stream";
            Response.Headers["X-Content-Type-Options"] = "nosniff";
            return File((byte[])dat.Rows[0]["Bytes"], type, fileName);
        }
    }

    public class ComposeRequest
    {
        public List<int> ToUIDs { get; set; }
        public string Subject { get; set; }
        public string Body { get; set; }
    }
}
