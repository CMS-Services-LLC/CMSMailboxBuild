using System;
using System.Linq;
using Google.Authenticator;
using Microsoft.AspNetCore.Mvc;
using Newtonsoft.Json.Linq;

namespace CMSMailbox.Controllers
{
    // Independent login implementation (not SSO with CMSNEO) that authenticates
    // against the SAME Users table and the SAME NEO_Login/2FA/IP-verification stored
    // procedures CMSNEO uses, so an account's password and already-enrolled TOTP
    // secret work identically on both apps. See CMS\Controllers\HomeController.cs
    // doLogin/Verify2FA (~line 152-339) for the flow this mirrors.
    //
    // Unlike CMS, there is no ASP.NET Session involved anywhere in this flow — the
    // login->2FA handoff uses a short-lived signed "pending" token instead (see
    // TokenGenerator.GeneratePendingMfaToken), and a successful 2FA check issues this
    // app's own session JWT directly.
    //
    // The one exception is auth/handoff: a one-time code CMSNEO issues to a user who
    // has already passed this same check there (Items Alerted On → open a message).
    [Route("auth")]
    public class AuthController : Controller
    {
        [HttpPost("login")]
        public IActionResult Login([FromBody] LoginRequest req)
        {
            string ip = HttpContext.Connection.RemoteIpAddress?.ToString() ?? "";
            string u = (req.Username ?? "").Replace("'", "");
            string p = (req.Password ?? "").Replace("'", "");
            string data = @"{U: '" + u + @"',P: '" + p + @"', IP: '" + ip + @"'}";

            var dat = DB.GetDB("exec NEO_Login @U, @P, @IP", 0, data);
            if (dat.Rows.Count == 0)
            {
                return Ok(new { status = "error" });
            }

            string errmsg;
            try { errmsg = dat.Rows[0]["err"].ToString(); } catch { errmsg = null; }
            if (errmsg != null)
            {
                return Ok(new { status = "error" });
            }

            string resultMsg;
            try { resultMsg = dat.Rows[0]["msg"].ToString(); } catch { resultMsg = ""; }

            if (resultMsg == "IP")
            {
                string auth = dat.Rows[0]["auth"].ToString();
                string ipEmail = dat.Rows[0]["email"].ToString();
                Mail.SendIPAuth(ipEmail, auth);
                return Ok(new { status = "bad_ip" });
            }

            if (resultMsg != "welcome")
            {
                return Ok(new { status = "bad_login" });
            }

            string strUID = dat.Rows[0]["uid"].ToString();
            string email = dat.Rows[0]["email"].ToString();
            string mfaToken = dat.Rows[0]["mfaToken"].ToString();
            string useMfaToken = dat.Rows[0]["useMfaToken"].ToString();

            var tfa = new TwoFactorAuthenticator();
            string uniqueKeyForUser = useMfaToken + DB.GmfaKey;
            SetupCode setupInfo = tfa.GenerateSetupCode("CMSMailbox", email, uniqueKeyForUser, false, 3);
            string barcodeUrl = (mfaToken == "") ? setupInfo.QrCodeSetupImageUrl : null;

            var tg = new TokenGenerator();
            string pendingToken = tg.GeneratePendingMfaToken(strUID, useMfaToken, email);

            return Ok(new { status = "mfa_required", pendingToken, barcodeUrl });
        }

        [HttpPost("verify2fa")]
        public IActionResult Verify2FA([FromBody] Verify2FARequest req)
        {
            if (!TokenGenerator.ValidatePendingMfaToken(req.PendingToken, out var uid, out var useMfaToken, out var email))
            {
                return Ok(new { status = "invalid_or_expired" });
            }

            var tfa = new TwoFactorAuthenticator();
            string uniqueKeyForUser = useMfaToken + DB.GmfaKey;
            bool isValid = tfa.ValidateTwoFactorPIN(uniqueKeyForUser, req.Passcode, TimeSpan.FromSeconds(5));

            // A one-time backup code from setup (sql/016) in place of the authenticator code.
            if (!isValid && BackupCodes.LooksLikeOne(req.Passcode))
            {
                var bc = DB.GetDB("exec MBX_UseBackupCode @email, @codeHash", 0,
                    new JObject { ["email"] = email, ["codeHash"] = BackupCodes.Hash(req.Passcode) }.ToString());
                isValid = bc.Rows.Count > 0 && bc.Columns.Contains("Used") && bc.Rows[0]["Used"].ToString() == "True";
            }

            if (!isValid)
            {
                return Ok(new { status = "invalid_passcode" });
            }

            DB.GetDB("exec NEO_UpdateUserMFA @email, @mfaToken", 0,
                new JObject { ["email"] = email, ["mfaToken"] = useMfaToken }.ToString());

            var tg = new TokenGenerator();
            string token = tg.GenerateToken(uid);

            return Ok(new { status = "ok", token });
        }

        // One-time handoff from CMSNEO's Items Alerted On (sql/011). CMSNEO issued the
        // code to a user who had already passed this same NEO_Login + 2FA check there;
        // MBX_RedeemHandoffCode accepts each code once, within 60 seconds, atomically.
        // Any failure looks the same to the caller and they get the normal login page.
        [HttpPost("handoff")]
        public IActionResult Handoff([FromBody] HandoffRequest req)
        {
            string code = req?.Code ?? "";
            if (code.Length != 64 || !code.All(Uri.IsHexDigit)) return Ok(new { status = "invalid_or_expired" });

            var dat = DB.GetDB("exec MBX_RedeemHandoffCode @code", 0, new JObject { ["code"] = code }.ToString());
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err") || !int.TryParse(dat.Rows[0]["UID"].ToString(), out int uid) || uid <= 0)
            {
                return Ok(new { status = "invalid_or_expired" });
            }

            var tg = new TokenGenerator();
            string token = tg.GenerateToken(uid.ToString());
            object messageId = dat.Rows[0]["MessageID"] == DBNull.Value ? null : dat.Rows[0]["MessageID"];

            return Ok(new { status = "ok", token, messageId });
        }

        // Sliding expiration, like CMSNEO's heartbeat: the page calls this every minute
        // while it's open and swaps in the fresh 60-minute token, so an open session's
        // token never runs out under it. Idle logout is the page's job (its inactivity
        // countdown), not this endpoint's. Only a valid session token is accepted —
        // ValidateAndGetUID refuses the pre-2FA pending token.
        [HttpPost("heartbeat")]
        public IActionResult Heartbeat()
        {
            string bearer = "";
            if (Request.Headers.TryGetValue(Microsoft.Net.Http.Headers.HeaderNames.Authorization, out var auth))
            {
                var parts = auth.FirstOrDefault()?.Split(' ');
                bearer = (parts != null && parts.Length > 1) ? parts[1] : "";
            }

            string uid = TokenGenerator.ValidateAndGetUID(bearer, out _);
            if (uid == "0") return Unauthorized();

            return Ok(new { token = new TokenGenerator().GenerateToken(uid) });
        }

        // Rebuilds the user's NEO_CacheUserAccess (NEO_ResetUserCreds), which NEO_NewSecurity — and so
        // the mailbox's own access gates — read from. CMS does this on every page load (global.js); the
        // page calls this on every load too, before it lists or opens anything. Without it a brand-new
        // user's cache is empty and every gate refuses them.
        [HttpPost("refresh-access")]
        public IActionResult RefreshAccess()
        {
            string bearer = "";
            if (Request.Headers.TryGetValue(Microsoft.Net.Http.Headers.HeaderNames.Authorization, out var auth))
            {
                var parts = auth.FirstOrDefault()?.Split(' ');
                bearer = (parts != null && parts.Length > 1) ? parts[1] : "";
            }

            if (!int.TryParse(TokenGenerator.ValidateAndGetUID(bearer, out _), out int uid) || uid == 0) return Unauthorized();

            DB.GetDB("exec NEO_ResetUserCreds @uid", uid);
            return Ok(new { status = "ok" });
        }

        // Who's logged in, for the top bar's "Logged in as:".
        [HttpGet("me")]
        public IActionResult Me()
        {
            string bearer = "";
            if (Request.Headers.TryGetValue(Microsoft.Net.Http.Headers.HeaderNames.Authorization, out var auth))
            {
                var parts = auth.FirstOrDefault()?.Split(' ');
                bearer = (parts != null && parts.Length > 1) ? parts[1] : "";
            }

            if (!int.TryParse(TokenGenerator.ValidateAndGetUID(bearer, out _), out int uid) || uid == 0) return Unauthorized();

            var dat = DB.GetDB(
                "select u.Fname + ' ' + u.Lname as Name, c.Company " +
                "from Users u left join Companies c on c.CID = dbo.mycid(u.UID) where u.UID = @uid", uid);
            if (dat.Rows.Count == 0 || dat.Columns.Contains("err")) return Ok(new { name = "", company = "" });

            return Ok(new { name = dat.Rows[0]["Name"]?.ToString() ?? "", company = dat.Rows[0]["Company"]?.ToString() ?? "" });
        }

        // CMSNEO's origin (scheme://host:port of AppSettings:CmsUrl) — not a secret. The
        // page accepts a handoff code posted from another tab (CMSNEO reusing an
        // already-open mailbox tab) only from this origin, so no other site can push
        // its own code into it and switch the user to a different account.
        [HttpGet("cms-origin")]
        public IActionResult CmsOrigin()
        {
            string origin = Uri.TryCreate(DB.CmsUrl ?? "", UriKind.Absolute, out var u) ? u.GetLeftPart(UriPartial.Authority) : "";
            return Ok(new { origin });
        }

        // Mirrors CMS's Validate action (HomeController.cs ~4445) for the new-IP
        // verification email link, against the same a_Suite_ValidateIP proc.
        [HttpGet("/Validate")]
        public IActionResult Validate(string auth, string deny)
        {
            string ip = HttpContext.Connection.RemoteIpAddress?.ToString() ?? "";
            bool isValid = false, isDenied = false;

            if (auth != null)
            {
                var dat = DB.GetDB("exec a_Suite_ValidateIP @ip, @auth", 0, "{\"ip\":\"" + ip + "\",\"auth\":\"" + auth + "\"}");
                if (dat.Rows.Count > 0) isValid = (bool)dat.Rows[0]["isValid"];
            }
            else if (deny != null)
            {
                DB.GetDB("exec a_Suite_DenyIPValidation @ip, @deny", 0, "{\"ip\":\"" + ip + "\",\"deny\":\"" + deny + "\"}");
                isDenied = true;
            }

            return Ok(new { isValid, isDenied });
        }
    }

    public class LoginRequest
    {
        public string Username { get; set; }
        public string Password { get; set; }
    }

    public class Verify2FARequest
    {
        public string PendingToken { get; set; }
        public string Passcode { get; set; }
    }

    public class HandoffRequest
    {
        public string Code { get; set; }
    }
}
