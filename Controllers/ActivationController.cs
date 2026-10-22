using System;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using Google.Authenticator;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Newtonsoft.Json.Linq;

namespace CMSMailbox.Controllers
{
    // First-time Secure Email onboarding (sql/016, wwwroot/activate.html). CMS emails a
    // single-use link to a recipient who has never completed 2FA; here they choose a password,
    // enroll their authenticator and get backup codes, then land signed in on the message.
    //
    // The account is the shared CMSNEO account, so this sets the same encPWD NEO_Login checks and
    // the same NEO_UserMFA secret (+ GmfaKey) both apps' 2FA use. Every failure answers
    // "invalid" without saying why (unknown, used, expired, or too many wrong codes).
    [Route("activate")]
    [EnableRateLimiting("activation")]
    public class ActivationController : Controller
    {
        // Same hash CMS's MailboxShareController stores: SHA-256 of the lowercase hex token.
        private static string TokenHash(string token)
        {
            if (string.IsNullOrEmpty(token) || token.Length != 64 || !token.All(Uri.IsHexDigit)) return null;
            return Convert.ToHexString(SHA256.HashData(Encoding.ASCII.GetBytes(token.ToLowerInvariant())));
        }

        private static System.Data.DataRow OpenLink(string tokenHash)
        {
            var dat = DB.GetDB("exec MBX_GetActivation @tokenHash", 0, new JObject { ["tokenHash"] = tokenHash }.ToString());
            return (dat.Rows.Count == 0 || dat.Columns.Contains("err")) ? null : dat.Rows[0];
        }

        [HttpPost("start")]
        public IActionResult Start([FromBody] ActivationStartRequest req)
        {
            string hash = TokenHash(req?.Token);
            var link = hash == null ? null : OpenLink(hash);
            if (link == null) return Ok(new { status = "invalid" });

            var setup = new TwoFactorAuthenticator().GenerateSetupCode(
                "CMS Secure Email", link["Email"].ToString(), link["MfaToken"] + DB.GmfaKey, false, 4);

            return Ok(new
            {
                status = "ok",
                firstName = link["FirstName"]?.ToString() ?? "",
                username = link["UserName"]?.ToString() ?? "",
                barcodeUrl = setup.QrCodeSetupImageUrl,
                manualKey = setup.ManualEntryKey
            });
        }

        [HttpPost("complete")]
        public IActionResult Complete([FromBody] ActivationCompleteRequest req)
        {
            string hash = TokenHash(req?.Token);
            var link = hash == null ? null : OpenLink(hash);
            if (link == null) return Ok(new { status = "invalid" });

            string problem = PasswordProblem(req.Password, link["UserName"]?.ToString());
            if (problem != null) return Ok(new { status = "bad_password", message = problem });

            var tfa = new TwoFactorAuthenticator();
            if (!tfa.ValidateTwoFactorPIN(link["MfaToken"] + DB.GmfaKey, (req.Passcode ?? "").Trim(), TimeSpan.FromSeconds(30)))
            {
                DB.GetDB("exec MBX_ActivationFailedCode @tokenHash", 0, new JObject { ["tokenHash"] = hash }.ToString());
                return Ok(new { status = "invalid_code" });
            }

            string[] codes = BackupCodes.Generate();
            string ip = HttpContext.Connection.RemoteIpAddress?.ToString() ?? "";

            var done = DB.GetDB("exec MBX_CompleteActivation @tokenHash, @pwd, @ip, @backupHashes", 0, new JObject
            {
                ["tokenHash"] = hash,
                ["pwd"] = req.Password,
                ["ip"] = ip,
                ["backupHashes"] = string.Join(",", codes.Select(BackupCodes.Hash))
            }.ToString());
            if (done.Rows.Count == 0 || done.Columns.Contains("err") || !int.TryParse(done.Rows[0]["UID"].ToString(), out int uid))
            {
                return Ok(new { status = "invalid" });
            }

            object messageId = done.Rows[0]["MessageID"] == DBNull.Value ? null : done.Rows[0]["MessageID"];

            return Ok(new
            {
                status = "ok",
                token = new TokenGenerator().GenerateToken(uid.ToString()),
                username = link["UserName"]?.ToString() ?? "",
                messageId,
                backupCodes = codes
            });
        }

        // 12+ characters with upper, lower, number and symbol. No apostrophe: both apps' login strips
        // it before hashing, so a password containing one could never be typed back in. 100 max:
        // Encrypted() hashes a varchar(100).
        private static string PasswordProblem(string pwd, string username)
        {
            pwd = pwd ?? "";
            if (pwd.Length < 12) return "Use at least 12 characters.";
            if (pwd.Length > 100) return "Use at most 100 characters.";
            if (pwd.Contains('\'')) return "Apostrophes (') can't be used.";
            if (pwd.Any(c => c > 126 || c < 32)) return "Use only standard keyboard characters.";
            if (!pwd.Any(char.IsUpper) || !pwd.Any(char.IsLower) || !pwd.Any(char.IsDigit) || pwd.All(char.IsLetterOrDigit))
                return "Include an uppercase letter, a lowercase letter, a number and a symbol.";
            if (!string.IsNullOrEmpty(username) && pwd.IndexOf(username, StringComparison.OrdinalIgnoreCase) >= 0)
                return "Don't include your username.";
            return null;
        }
    }

    public class ActivationStartRequest
    {
        public string Token { get; set; }
    }

    public class ActivationCompleteRequest
    {
        public string Token { get; set; }
        public string Password { get; set; }
        public string Passcode { get; set; }
    }
}
