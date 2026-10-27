using System.Collections.Generic;
using System.Data;
using MailKit.Net.Smtp;
using MimeKit;

namespace CMSMailbox
{
    // Minimal port of CMS\sendMail.cs's csMail — only the new-IP verification email,
    // since that's the one piece of CMS's login flow this app's own login needs to
    // replicate. Reads the same NEO_NoReplyEmailCreds table CMS uses.
    public static class Mail
    {
        private static List<string> Creds()
        {
            List<string> creds = new List<string>();
            DataTable d = DB.GetDB("select * from NEO_NoReplyEmailCreds where active=1", 0, "{}");
            creds.Add(d.Rows[0]["MsgFromName"].ToString());
            creds.Add(d.Rows[0]["MsgFromAddr"].ToString());
            creds.Add(d.Rows[0]["MsgFromUser"].ToString());
            creds.Add(d.Rows[0]["MsgFromPwd"].ToString());
            return creds;
        }

        // Thin branded footer appended to every email this app sends.
        private const string Footer =
            "<table role=\"presentation\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" width=\"100%\" style=\"max-width:600px; margin:20px auto 0; background-color:#ffffff; border-top:3px solid #015390;\">" +
              "<tr><td style=\"padding:10px 16px; text-align:center; background-color:#f8fafc;\">" +
                "<table role=\"presentation\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" width=\"100%\"><tr>" +
                  "<td style=\"text-align:center; padding-bottom:6px;\">" +
                    "<span style=\"font-size:13px; color:#333333; font-weight:600;\">Access full CMS operations &rarr; </span>" +
                    "<a href=\"https://portal.cms-services.net\" target=\"_blank\" style=\"display:inline-block; background-color:#015390; color:#ffffff; padding:6px 16px; font-size:13px; font-weight:bold; text-decoration:none; border-radius:4px;\">Log In to Portal</a>" +
                  "</td>" +
                "</tr></table>" +
              "</td></tr>" +
              "<tr><td style=\"padding:6px 16px; background-color:#015390; color:#ffffff; font-size:10px; line-height:1.4; text-align:center;\">" +
                "CMS Secure Email &nbsp;&middot;&nbsp; Confidential &ndash; intended only for the named recipient(s)." +
              "</td></tr>" +
            "</table>";

        public static void SendIPAuth(string email, string auth)
        {
            var creds = Creds();

            var message = new MimeMessage();
            message.From.Add(new MailboxAddress(creds[0], creds[1]));
            message.To.Add(new MailboxAddress("", email));
            message.Subject = "CMS Secure Mailbox IP Validation";
            message.Body = new TextPart("html")
            {
                Text = "<p>You have attempted to log in to the CMS Secure Mailbox from an unknown location.</p>" +
                "<p>Please click the link below to validate this location and enter the site.</p>" +
                @"<p><a href=""" + DB.Url + @"/Validate?auth=" + auth + @""">Validate my IP Address</a></p>" +
                "<p style=\"color:red\">*** If you believe a login was attempted by someone other than yourself, please click the link below.</p>" +
                @"<p><a href=""" + DB.Url + @"/Validate?deny=" + auth + @""">Deny Validation from this IP Address</a></p>" +
                Footer
            };

            using (var client = new SmtpClient())
            {
                client.Connect("smtp.office365.com", 587);
                client.Authenticate(creds[2], creds[3]);
                client.Send(message);
                client.Disconnect(true);
            }
        }

        // A new secure message (or reply) sent from the mailbox itself (sql/029). Same wording as
        // CMS's notification (MailboxShareController.SendShareNotificationEmails): no content, only
        // a link, and the sender's name and company in the subject.
        public static void SendNewMessageNotification(string email, string senderName, string senderCompany, int messageId)
        {
            var creds = Creds();
            string from = string.IsNullOrEmpty(senderName) ? "" :
                " from " + senderName + (string.IsNullOrEmpty(senderCompany) ? "" : " (" + senderCompany + ")");
            string link = DB.Url.TrimEnd('/') + "/?message=" + messageId;

            var message = new MimeMessage();
            message.From.Add(new MailboxAddress(creds[0], creds[1]));
            message.To.Add(new MailboxAddress("", email));
            message.Subject = "You have a new secure message" + from;
            message.Body = new TextPart("html")
            {
                Text = "<p>You have a new secure message waiting for you" +
                    (string.IsNullOrEmpty(senderName) ? "" : " from <b>" + System.Net.WebUtility.HtmlEncode(senderName) +
                        (string.IsNullOrEmpty(senderCompany) ? "" : " (" + System.Net.WebUtility.HtmlEncode(senderCompany) + ")") + "</b>") +
                    ".</p>" +
                    "<p><a href=\"" + link + "\">Open it in the CMS Secure Mailbox</a></p>" +
                    "<hr style=\"border:none;border-top:1px solid #ccc;margin:20px 0\">" +
                    "<p style=\"font-size:11px;color:#777\">This is an automated notification from CMS Secure Mailbox. " +
                    "It does not contain any confidential information — sign in to CMS Secure Mailbox with your own " +
                    "credentials to view the message. If you were not expecting this message, please " +
                    "contact your system administrator.</p>" +
                    Footer
            };

            using (var client = new SmtpClient())
            {
                client.Connect("smtp.office365.com", 587);
                client.Authenticate(creds[2], creds[3]);
                client.Send(message);
                client.Disconnect(true);
            }
        }
    }
}
