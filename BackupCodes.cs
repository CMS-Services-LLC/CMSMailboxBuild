using System;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace CMSMailbox
{
    // One-time 2FA backup codes from Secure Email setup (sql/016). Shown to the user once as
    // "xxxxx-xxxxx"; only the SHA-256 of the normalized code (lowercase letters/digits, no dash)
    // is stored. CMS's Verify2FA (HomeController) hashes the same way — keep the two in step.
    public static class BackupCodes
    {
        // No 0/o, 1/l/i: easy to read back off paper.
        private const string Alphabet = "abcdefghjkmnpqrstuvwxyz23456789";

        public static string[] Generate(int count = 10)
        {
            return Enumerable.Range(0, count).Select(_ =>
            {
                var chars = Enumerable.Range(0, 10).Select(__ => Alphabet[RandomNumberGenerator.GetInt32(Alphabet.Length)]).ToArray();
                return new string(chars, 0, 5) + "-" + new string(chars, 5, 5);
            }).ToArray();
        }

        public static string Normalize(string code)
        {
            return new string((code ?? "").Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();
        }

        public static string Hash(string code)
        {
            return Convert.ToHexString(SHA256.HashData(Encoding.ASCII.GetBytes(Normalize(code))));
        }

        public static bool LooksLikeOne(string input) => Normalize(input).Length == 10;
    }
}
