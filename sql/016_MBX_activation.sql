/*
	016_MBX_activation.sql  (2026-10-22)

	First-time Secure Email onboarding. When a secure message goes to someone who has never finished
	logging in (no active NEO_UserMFA row for their email, i.e. never completed 2FA on CMS or CMSMailbox),
	CMS sends the "Welcome to CMS Secure Email – Activate Your Account" email instead of the plain
	notification. Its link opens CMSMailbox's activate.html, where they choose their own password, scan the
	authenticator QR code and confirm a 6-digit code, then land on the message.

	- Only a SHA-256 hash of the link's token is stored. The raw token exists only in the email.
	- A link works once, for 48 hours, and for at most 10 wrong authenticator codes.
	- Completing one link uses up every other open link for the same person.
	- The password is stored the way NEO_Login checks it (Encrypted() = SHA2_512 in encPWD). UserPWD (the
	  plaintext copy) is cleared for this user, and it is never written here.
	- The authenticator secret is the existing scheme (NEO_UserMFA.MFAToken + the app's GmfaKey), so the
	  same code works on CMS and CMSMailbox.
	- Finishing counts as validating the IP the link was opened from (UserAuth), the same thing the
	  "Validate my IP Address" email does, since the link already proves they hold the mailbox.

	- Setup ends with 10 one-time backup codes, shown once. Only their SHA-256 is stored (MBX_BackupCode), tied
	  to the authenticator secret they were issued with, so a later Reset 2FA retires them. CMS and CMSMailbox
	  login both accept one in place of the authenticator code (MBX_UseBackupCode).

	None of these procs are reachable from CMS's browser dispatcher (it only runs NEO* and a_Suite_*).

	Safe to re-run.
*/

if object_id('dbo.MBX_Activation') is null
begin
	create table dbo.MBX_Activation (
		ActivationID int identity(1,1) not null constraint PK_MBX_Activation primary key,
		UID int not null constraint FK_MBX_Activation_Users references dbo.Users(UID),
		TokenHash varbinary(32) not null,
		MessageID int null,
		MfaToken varchar(100) null,
		Attempts int not null constraint DF_MBX_Activation_Attempts default 0,
		CreatedBy int not null,
		DTCreated datetime not null constraint DF_MBX_Activation_DTCreated default getdate(),
		DTExpires datetime not null,
		DTUsed datetime null
	)
	create unique index UX_MBX_Activation_TokenHash on dbo.MBX_Activation(TokenHash)
	create index IX_MBX_Activation_UID on dbo.MBX_Activation(UID) include (DTUsed)
end
GO

if object_id('dbo.MBX_BackupCode') is null
begin
	create table dbo.MBX_BackupCode (
		BackupCodeID int identity(1,1) not null constraint PK_MBX_BackupCode primary key,
		Email varchar(200) not null,
		MfaToken varchar(100) not null,
		CodeHash varbinary(32) not null,
		DTCreated datetime not null constraint DF_MBX_BackupCode_DTCreated default getdate(),
		DTUsed datetime null
	)
	create index IX_MBX_BackupCode_Email on dbo.MBX_BackupCode(Email, CodeHash)
end
GO

-- 1 when this user has never completed 2FA anywhere (CMS and CMSMailbox share NEO_UserMFA by email).
create or alter function dbo.MBX_NeedsActivation(@uid int)
returns bit
as begin
	declare @needs bit = 0
	select @needs = 1
	from users u
	where u.uid = @uid and u.active = 1 and isnull(u.email, '') <> ''
	  and not exists (select 1 from NEO_UserMFA m where m.email = u.email and m.active = 1)
	return @needs
end
GO

-- Called by CMS right after a share/task message is created, once per recipient.
-- @tokenHash = hex SHA-256 of the raw token CMS will put in the email.
-- Returns NeedsActivation; when 1 the link row was stored and CMS sends the welcome email.
create or alter procedure dbo.MBX_CreateActivation
	@uid int, @xuid int, @messageId int, @tokenHash varchar(64)
as begin
	set nocount on
	declare @needs bit = dbo.MBX_NeedsActivation(@xuid)

	-- only the message's author, for one of its own recipients
	if not exists (
		select 1 from MBX_Message m
		join MBX_Recipient r on r.MessageID = m.MessageID and r.ToUID = @xuid
		where m.MessageID = @messageId and m.FromUID = @uid
	)
		set @needs = 0

	if @needs = 1
		insert into MBX_Activation(UID, TokenHash, MessageID, CreatedBy, DTExpires)
		select @xuid, convert(varbinary(32), @tokenHash, 2), @messageId, @uid, dateadd(hour, 48, getdate())

	select @needs as NeedsActivation, u.Fname as FirstName
	from users u where u.uid = @xuid
end
GO

-- The open link for this token, or no row. Gives the link its authenticator secret on first use.
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

	update MBX_Activation set MfaToken = cast(newid() as varchar(100)) where ActivationID = @id and MfaToken is null

	select a.UID, u.UserName, u.Fname as FirstName, u.Email, a.MfaToken, a.MessageID
	from MBX_Activation a
	join users u on u.uid = a.UID
	where a.ActivationID = @id
end
GO

create or alter procedure dbo.MBX_ActivationFailedCode
	@tokenHash varchar(64)
as begin
	set nocount on
	update MBX_Activation set Attempts = Attempts + 1
	where TokenHash = convert(varbinary(32), @tokenHash, 2) and DTUsed is null
end
GO

-- Sets the password, enrolls 2FA, stores the backup codes, validates the IP and spends the user's links,
-- all or nothing. CMSMailbox has already checked the authenticator code and the password rules.
-- @backupHashes = comma-separated hex SHA-256 of each backup code.
create or alter procedure dbo.MBX_CompleteActivation
	@tokenHash varchar(64), @pwd varchar(100), @ip varchar(100), @backupHashes varchar(max)
as begin
	set nocount on
	set xact_abort on
	declare @hash varbinary(32) = convert(varbinary(32), @tokenHash, 2)
	declare @id int, @uid int, @mfa varchar(100), @email varchar(300), @messageId int

	begin tran
		select @id = a.ActivationID, @uid = a.UID, @mfa = a.MfaToken, @messageId = a.MessageID
		from MBX_Activation a with (updlock, holdlock)
		where a.TokenHash = @hash and a.DTUsed is null and a.DTExpires > getdate() and a.Attempts < 10 and a.MfaToken is not null

		if @id is null or dbo.MBX_NeedsActivation(@uid) = 0 begin
			rollback
			return
		end

		select @email = email from users where uid = @uid

		update u set encPWD = x.enc, UserPWD = null
		from users u
		join Encrypted(@pwd) x on u.uid = @uid

		insert into NEO_UserMFA(MFAToken, Email) select @mfa, @email

		update MBX_BackupCode set DTUsed = getdate() where Email = @email and DTUsed is null
		insert into MBX_BackupCode(Email, MfaToken, CodeHash)
		select @email, @mfa, convert(varbinary(32), ltrim(rtrim(value)), 2)
		from string_split(@backupHashes, ',') where ltrim(rtrim(value)) <> ''

		if @ip <> '' and not exists (select 1 from UserAuth where uid = @uid and ip = @ip)
			insert into UserAuth(UID, IP, DT) select @uid, @ip, getdate()

		update MBX_Activation set DTUsed = getdate() where UID = @uid and DTUsed is null
	commit

	exec insertAction @uid, 'Activated', 'MBX_CompleteActivation', '', 'done'

	select @uid as UID, @messageId as MessageID
end
GO

-- Login with a backup code instead of the authenticator code (CMS Verify2FA and CMSMailbox auth/verify2fa).
-- Spends the code; only codes issued with the email's current authenticator secret count.
create or alter procedure dbo.MBX_UseBackupCode
	@email varchar(200), @codeHash varchar(64)
as begin
	set nocount on
	declare @used int = 0

	update b set DTUsed = getdate()
	from MBX_BackupCode b
	join NEO_UserMFA m on m.email = b.Email and m.active = 1 and m.MFAToken = b.MfaToken
	where b.Email = @email and b.CodeHash = convert(varbinary(32), @codeHash, 2) and b.DTUsed is null
	set @used = @@rowcount

	if @used > 0
		exec insertAction 0, 'BackupCodeLogin', 'MBX_UseBackupCode', @email, 'done'

	select cast(case when @used > 0 then 1 else 0 end as bit) as Used
end
GO
