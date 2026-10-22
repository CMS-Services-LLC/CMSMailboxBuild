/*
	diag_016_activation.sql  (2026-10-22) - read-only diagnostic, run on QA.
	Why did the new assignee get the plain "new secure message" email instead of the activation email?
	Put the new user's username in @username, run, and send back all four result sets.
*/
declare @username varchar(200) = 'PUT-NEW-USERNAME-HERE'
declare @uid int = (select max(uid) from users where username = @username)
declare @email varchar(300) = (select email from users where uid = @uid)

-- 1. The account, and whether 016 thinks it still needs activation
select u.UID, u.UserName, u.Email, u.CID, u.Active, u.created,
	dbo.MBX_NeedsActivation(u.UID) as NeedsActivation,
	(select count(*) from NEO_UserMFA m where m.email = u.email and m.active = 1) as ActiveMfaRowsForEmail,
	(select count(*) from users o where o.email = u.email and o.uid <> u.uid) as OtherAccountsWithSameEmail
from users u where u.uid = @uid

-- 2. Other accounts sharing that email (a 2FA set up on any of them counts for all)
select o.UID, o.UserName, o.CID, o.Active from users o where o.email = @email and o.uid <> @uid

-- 3. The messages sent to him, newest first
select top 5 m.MessageID, m.FromUID, m.Subject, m.DTCreated, r.ToUID
from MBX_Recipient r join MBX_Message m on m.MessageID = r.MessageID
where r.ToUID = @uid order by m.MessageID desc

-- 4. Any activation links stored for him (a row here means the link was created but the email send failed)
select ActivationID, UID, MessageID, CreatedBy, DTCreated, DTExpires, DTUsed, Attempts
from MBX_Activation where UID = @uid order by ActivationID desc
