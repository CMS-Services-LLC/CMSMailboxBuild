/*
	017_MBX_activation_per_account.sql  (2026-10-22)   run after 016

	"Never logged in" is now per ACCOUNT (UID), not per email address. In 016 an account counted as set up
	whenever ANY account with the same email had 2FA, so a brand-new account sharing an email with an
	existing user got the plain notification instead of the activation email.

	An account still needs activation unless BOTH are true:
	  - it has signed in before: it has a validated login IP (UserAuth, or UserAuthExpired after 6 months).
	    NEO_Login refuses every password login until the account's IP is validated, so every account that
	    has ever signed in has one, and a new account has none;
	  - its email has an authenticator (active NEO_UserMFA).
	Once the account finishes an activation link it never needs another.

	When the email already has an authenticator (another account with the same email set it up), the link
	skips the QR code: the person sets this account's password and confirms with the authenticator they
	already have (CMS and CMSMailbox use one authenticator per email). Otherwise it enrolls one as in 016.

	Every skip is now logged in a_Suite_Actions (title 'ActivationSkipped', the reason in params), and a
	failed send in 'ActivationEmailFailed', so a missing activation email can be explained.

	Safe to re-run.
*/

if col_length('dbo.MBX_Activation', 'Completed') is null
	alter table dbo.MBX_Activation add Completed bit not null constraint DF_MBX_Activation_Completed default 0
GO

create or alter function dbo.MBX_NeedsActivation(@uid int)
returns bit
as begin
	declare @needs bit = 0
	select @needs = 1
	from users u
	where u.uid = @uid and u.active = 1 and isnull(u.email, '') <> ''
	  and not exists (select 1 from MBX_Activation a where a.UID = u.uid and a.Completed = 1)
	  and (
		not exists (select 1 from UserAuth ua where ua.uid = u.uid)
			and not exists (select 1 from userAuthExpired ue where ue.uid = u.uid)
		or not exists (select 1 from NEO_UserMFA m where m.email = u.email and m.active = 1)
	  )
	return @needs
end
GO

-- The email's current authenticator secret, or null.
create or alter function dbo.MBX_ActiveMfaToken(@email varchar(300))
returns varchar(100)
as begin
	return (select top 1 MFAToken from NEO_UserMFA where email = @email and active = 1 order by id desc)
end
GO

create or alter procedure dbo.MBX_CreateActivation
	@uid int, @xuid int, @messageId int, @tokenHash varchar(64)
as begin
	set nocount on
	declare @needs bit = dbo.MBX_NeedsActivation(@xuid)
	declare @reason varchar(200) = case when @needs = 1 then '' else 'already signed in before, or inactive / no email' end

	-- only the message's author, for one of its own recipients
	if not exists (
		select 1 from MBX_Message m
		join MBX_Recipient r on r.MessageID = m.MessageID and r.ToUID = @xuid
		where m.MessageID = @messageId and m.FromUID = @uid
	)
		select @needs = 0, @reason = 'not a recipient of this message from this sender'

	if @needs = 1
		insert into MBX_Activation(UID, TokenHash, MessageID, CreatedBy, DTExpires)
		select @xuid, convert(varbinary(32), @tokenHash, 2), @messageId, @uid, dateadd(hour, 48, getdate())
	else begin
		declare @p varchar(400) = 'xuid=' + cast(@xuid as varchar) + ',messageId=' + cast(@messageId as varchar) + ',reason=' + @reason
		exec insertAction @uid, 'ActivationSkipped', 'MBX_CreateActivation', @p, 'done'
	end

	select @needs as NeedsActivation, @reason as Reason, u.Fname as FirstName
	from users u where u.uid = @xuid
end
GO

-- The open link for this token, or no row. HasAuthenticator = the email already has one, so the page
-- asks for a code from it instead of showing a QR code.
create or alter procedure dbo.MBX_GetActivation
	@tokenHash varchar(64)
as begin
	set nocount on
	declare @hash varbinary(32) = convert(varbinary(32), @tokenHash, 2)
	declare @id int, @uid int

	select @id = a.ActivationID, @uid = a.UID
	from MBX_Activation a
	where a.TokenHash = @hash and a.DTUsed is null and a.DTExpires > getdate() and a.Attempts < 10

	-- set up some other way since the email went out: the link is spent
	if @id is not null and dbo.MBX_NeedsActivation(@uid) = 0 begin
		update MBX_Activation set DTUsed = getdate() where ActivationID = @id
		set @id = null
	end

	if @id is null return

	declare @existing varchar(100) = dbo.MBX_ActiveMfaToken((select email from users where uid = @uid))

	update MBX_Activation
	set MfaToken = coalesce(@existing, case when MfaToken is null or MfaToken = '' then cast(newid() as varchar(100)) else MfaToken end)
	where ActivationID = @id

	-- an earlier visit may have stored the email's old secret; a fresh one is generated if that was reset
	update a set MfaToken = cast(newid() as varchar(100))
	from MBX_Activation a
	where a.ActivationID = @id and @existing is null
	  and exists (select 1 from NEO_UserMFA m where m.MFAToken = a.MfaToken)

	select a.UID, u.UserName, u.Fname as FirstName, u.Email, a.MfaToken, a.MessageID,
		cast(case when @existing is null then 0 else 1 end as bit) as HasAuthenticator
	from MBX_Activation a
	join users u on u.uid = a.UID
	where a.ActivationID = @id
end
GO

-- Sets this account's password, enrolls 2FA if the email has none, stores the backup codes, validates
-- the IP and spends the account's links, all or nothing.
create or alter procedure dbo.MBX_CompleteActivation
	@tokenHash varchar(64), @pwd varchar(100), @ip varchar(100), @backupHashes varchar(max)
as begin
	set nocount on
	set xact_abort on
	declare @hash varbinary(32) = convert(varbinary(32), @tokenHash, 2)
	declare @id int, @uid int, @mfa varchar(100), @email varchar(300), @messageId int, @existing varchar(100)

	begin tran
		select @id = a.ActivationID, @uid = a.UID, @mfa = a.MfaToken, @messageId = a.MessageID
		from MBX_Activation a with (updlock, holdlock)
		where a.TokenHash = @hash and a.DTUsed is null and a.DTExpires > getdate() and a.Attempts < 10 and a.MfaToken is not null

		select @email = email from users where uid = @uid
		set @existing = dbo.MBX_ActiveMfaToken(@email)

		-- the code was checked against @mfa: it must still be the email's authenticator, or a new one
		if @id is null or dbo.MBX_NeedsActivation(@uid) = 0 or (@existing is not null and @existing <> @mfa) begin
			rollback
			return
		end

		update u set encPWD = x.enc, UserPWD = null
		from users u
		join Encrypted(@pwd) x on u.uid = @uid

		if @existing is null
			insert into NEO_UserMFA(MFAToken, Email) select @mfa, @email

		update MBX_BackupCode set DTUsed = getdate() where Email = @email and DTUsed is null
		insert into MBX_BackupCode(Email, MfaToken, CodeHash)
		select @email, @mfa, convert(varbinary(32), ltrim(rtrim(value)), 2)
		from string_split(@backupHashes, ',') where ltrim(rtrim(value)) <> ''

		if @ip <> '' and not exists (select 1 from UserAuth where uid = @uid and ip = @ip)
			insert into UserAuth(UID, IP, DT) select @uid, @ip, getdate()

		update MBX_Activation set DTUsed = getdate(), Completed = case when ActivationID = @id then 1 else Completed end
		where UID = @uid and DTUsed is null
	commit

	exec insertAction @uid, 'Activated', 'MBX_CompleteActivation', '', 'done'

	select @uid as UID, @messageId as MessageID
end
GO

-- CMS couldn't send the activation email: spend the link and say so in a_Suite_Actions.
create or alter procedure dbo.MBX_ActivationEmailFailed
	@uid int, @tokenHash varchar(64)
as begin
	set nocount on
	declare @xuid int
	select @xuid = UID from MBX_Activation where TokenHash = convert(varbinary(32), @tokenHash, 2)
	update MBX_Activation set DTUsed = getdate() where TokenHash = convert(varbinary(32), @tokenHash, 2) and DTUsed is null
	declare @p varchar(100) = 'xuid=' + isnull(cast(@xuid as varchar), '?')
	exec insertAction @uid, 'ActivationEmailFailed', 'MBX_ActivationEmailFailed', @p, 'done'
end
GO
