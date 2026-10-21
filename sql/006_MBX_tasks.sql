/*
	Tasks assigned through the secure mailbox ("What would you like to do?" → Assign a
	Task, on the CMSNEO dashboard). See WizardAssignments_Plan.md.

	Phase 1 only implements TaskType = 'FormApplication': a management-company user
	asks one assignee to fill out a NEW record of a given form. The task rides on an
	ordinary MBX_MessageItem of ItemType 'IAFormRecord' whose ItemID is '0' (no record
	yet) — CMSMailbox's IaViewerController treats ItemID '0' + an open task assigned to
	the caller as "new-record mode". On the first save, MBX_CompleteFormTask swaps the
	item's ItemID to the new MainID, so every later open of that same item goes through
	the existing, unchanged gated path (Gate A + Gate B) like any shared record.

	Like Share to Mailbox, assigning a task grants no access: the assignee must already
	hold the form's Team grant (Gate A), re-checked by CMSMailbox on every request.

	- MBX_Task: new table (columns for the later DynamicReport/Exam phases included
	  now so the table doesn't need reshaping later).
	- MBX_CreateTask, MBX_GetOpenFormTask, MBX_CompleteFormTask: new.
	- MBX_GetFormTaskCandidates: new. Recipient picker for a form task — same rules as
	  NEO_IAGetRecipients, but keyed on a FormID instead of an existing record.
	- MBX_GetMessage: items now also carry TaskID/TaskType/TaskStatus/DueDate.
	  Existing columns unchanged.
	- MBX_SendReply: no longer carries a not-yet-started task item ('0') onto a reply
	  (the reply's recipients have no task, so it could never open for them).

	Idempotent; safe to run more than once. Requires 001-005.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.MBX_Task', 'U') IS NULL
BEGIN
	CREATE TABLE [dbo].[MBX_Task](
		[TaskID] [int] IDENTITY(1,1) NOT NULL,
		[MessageItemID] [int] NOT NULL,
		[TaskType] [varchar](20) NOT NULL,
		[AssignedByUID] [int] NOT NULL,
		[AssignedToUID] [int] NOT NULL,
		[FormID] [varchar](100) NULL,
		[ExamID] [varchar](100) NULL,
		[ExamCID] [int] NULL,
		[ReportName] [nvarchar](255) NULL,
		[ReportType] [nvarchar](100) NULL,
		[TemplateFileName] [nvarchar](255) NULL,
		[TemplateHeaders] [nvarchar](max) NULL,
		[TemplateBytes] [varbinary](max) NULL,
		[ResultID] [nvarchar](100) NULL,
		[Status] [varchar](20) NOT NULL CONSTRAINT [DF_MBX_Task_Status] DEFAULT ('Open'),
		[DueDate] [date] NULL,
		[DTCreated] [datetime] NOT NULL CONSTRAINT [DF_MBX_Task_DTCreated] DEFAULT (getdate()),
		[DTCompleted] [datetime] NULL,
	 CONSTRAINT [PK_MBX_Task] PRIMARY KEY CLUSTERED ([TaskID] ASC),
	 CONSTRAINT [FK_MBX_Task_MBX_MessageItem] FOREIGN KEY([MessageItemID]) REFERENCES [dbo].[MBX_MessageItem] ([MessageItemID]),
	 CONSTRAINT [CK_MBX_Task_TaskType] CHECK ([TaskType] IN ('FormApplication','DynamicReport','Exam')),
	 CONSTRAINT [CK_MBX_Task_Status] CHECK ([Status] IN ('Open','Completed','Cancelled'))
	) ON [PRIMARY]

	CREATE UNIQUE NONCLUSTERED INDEX [IX_MBX_Task_MessageItemID] ON [dbo].[MBX_Task] ([MessageItemID] ASC)
	CREATE NONCLUSTERED INDEX [IX_MBX_Task_AssignedToUID] ON [dbo].[MBX_Task] ([AssignedToUID] ASC)
END
GO

-- Called by CMS's MailboxShareController right after MBX_SendMessage/MBX_AddRecipients/
-- MBX_AddMessageItems. Only the message's own author can attach a task to one of its
-- items, and only for someone who is actually a recipient of that message.
CREATE OR ALTER PROCEDURE [dbo].[MBX_CreateTask]
	@UID INT,
	@MessageItemID INT,
	@TaskType VARCHAR(20),
	@AssignedToUID INT,
	@FormID VARCHAR(100) = NULL,
	@DueDate VARCHAR(20) = NULL
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF NOT EXISTS (
		SELECT 1
		FROM MBX_MessageItem mi
		JOIN MBX_Message m ON m.MessageID = mi.MessageID AND m.FromUID = @UID
		JOIN MBX_Recipient r ON r.MessageID = mi.MessageID AND r.ToUID = @AssignedToUID
		WHERE mi.MessageItemID = @MessageItemID
	)
	BEGIN
		SELECT 'not the author of this message, or assignee is not a recipient' AS err
		RETURN
	END

	INSERT INTO MBX_Task (MessageItemID, TaskType, AssignedByUID, AssignedToUID, FormID, DueDate)
	SELECT @MessageItemID, @TaskType, @UID, @AssignedToUID, NULLIF(@FormID, ''), TRY_CONVERT(date, NULLIF(@DueDate, ''))

	SELECT SCOPE_IDENTITY() AS TaskID
END
GO

-- New-record mode lookup for CMSMailbox's IaViewerController. Returns the task's
-- FormID only when ALL of these hold: the item is an IAFormRecord item with no record
-- yet ('0'), the caller is a recipient of its message, and an Open FormApplication
-- task on that item is assigned to the caller. Returns nothing otherwise.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetOpenFormTask]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT t.TaskID, t.FormID
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	JOIN MBX_Recipient r ON r.MessageID = mi.MessageID AND r.ToUID = @UID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'FormApplication'
	AND t.Status = 'Open'
	AND t.AssignedToUID = @UID
	AND mi.ItemType = 'IAFormRecord'
	AND mi.ItemID = '0'
	AND t.FormID IS NOT NULL
END
GO

-- Links the record the assignee just created to the task's item and marks the task
-- Completed. Re-validates everything rather than trusting the caller's MainID: the
-- task must still be open for this caller, and the record must be an active record of
-- the task's form that this caller created.
CREATE OR ALTER PROCEDURE [dbo].[MBX_CompleteFormTask]
	@UID INT,
	@MessageItemID INT,
	@MainID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @TaskID INT, @FormID VARCHAR(100)

	SELECT @TaskID = t.TaskID, @FormID = t.FormID
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'FormApplication'
	AND t.Status = 'Open'
	AND t.AssignedToUID = @UID
	AND mi.ItemID = '0'

	IF @TaskID IS NULL
	BEGIN
		SELECT 'no open form task for this item and user' AS err
		RETURN
	END

	IF NOT EXISTS (
		SELECT 1 FROM NEO_IAFormRecords
		WHERE ID = @MainID AND FormID = @FormID AND UID = @UID AND active = 1
	)
	BEGIN
		SELECT 'record is not a new record of this form created by this user' AS err
		RETURN
	END

	UPDATE MBX_MessageItem SET ItemID = CAST(@MainID AS NVARCHAR(50))
	WHERE MessageItemID = @MessageItemID

	UPDATE MBX_Task SET Status = 'Completed', ResultID = CAST(@MainID AS NVARCHAR(100)), DTCompleted = getdate()
	WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID, @MainID AS MainID
END
GO

-- Recipient picker for a FormApplication task. Mirrors NEO_IAGetRecipients' rules
-- (form Team grants if the form has any, else the 'Form Applications' user group,
-- plus Global Admins; deduped to each person's real MGT account), except there is no
-- record yet: candidate companies are the caller's whole network (neousers), and the
-- Team company-group restriction is checked against each candidate's own company,
-- since that is the company a record they create would belong to.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetFormTaskCandidates]
	@UID INT,
	@FormID VARCHAR(100)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @groups TABLE(GroupType VARCHAR(100), GroupID VARCHAR(100))
	INSERT INTO @groups
	SELECT GroupType, GroupID FROM NEO_IAFormAccess WHERE formid = @FormID AND active = 1

	DECLARE @teams INT = (SELECT count(*) FROM @groups WHERE GroupType = 'Team')

	DECLARE @main TABLE(MgtUID INT, Name VARCHAR(200), Email VARCHAR(300), Company VARCHAR(300))

	IF @teams > 0
		INSERT INTO @main
		SELECT u.MgtUID, u.Name, u.Email, u.Company
		FROM neousers(@UID) u
		JOIN NEO_SecurityTeamAssignments sta ON sta.uid = u.MgtUID AND sta.active = 1
		JOIN NEO_SecurityTeamGroups stg ON stg.GroupID = sta.GroupID AND stg.active = 1
		JOIN @groups g ON g.GroupType = 'Team' AND g.GroupID = stg.GroupID
		LEFT JOIN NEO_SecurityTeamCompanyGroups stcg ON stcg.TeamID = g.GroupID AND stcg.active = 1
		LEFT JOIN Neo_CompanyGroups cg ON cg.groupid = stcg.CompanyGroupID AND cg.active = 1
		LEFT JOIN Neo_CompanyGroupAssignments cga ON cga.GroupID = cg.GroupID AND cga.active = 1 AND cga.xcid = u.cid
		WHERE stcg.id IS NULL OR cga.id IS NOT NULL
	ELSE
		INSERT INTO @main
		SELECT u.MgtUID, u.Name, u.Email, u.Company
		FROM neousers(@UID) u
		JOIN NEO_SecurityGroupAssignments sga ON sga.uid = u.MgtUID AND sga.active = 1
		JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action = 'Form Applications'

	INSERT INTO @main
	SELECT u.MgtUID, u.Name, u.Email, u.Company
	FROM neousers(@UID) u
	JOIN NEO_SecurityGroupAssignments sga ON sga.uid = u.MgtUID AND sga.active = 1
	JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action = 'Global Administrator'

	SELECT DISTINCT MgtUID AS UID, Name, Email, Company
	FROM @main
	WHERE MgtUID <> @UID
	ORDER BY Name
END
GO

-- Same as 005's version, plus the task columns on the item result set.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetMessage]
	@UID INT,
	@MessageID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @IsRecipient BIT = 0, @IsArchived BIT = 0

	SELECT @IsRecipient = 1, @IsArchived = IsArchived
	FROM MBX_Recipient
	WHERE MessageID = @MessageID AND ToUID = @UID

	-- Recipient OR author. Deliberately returns nothing distinguishable from "message
	-- doesn't exist" for anyone else — never confirm existence of a message the
	-- caller has no relationship to.
	IF @IsRecipient = 0 AND NOT EXISTS (
		SELECT 1 FROM MBX_Message WHERE MessageID = @MessageID AND FromUID = @UID
	)
	BEGIN
		RETURN
	END

	SELECT
		m.MessageID, m.Subject, m.Body, m.DTCreated, m.ReplyToMessageID,
		u.Fname + ' ' + u.Lname AS FromName,
		c.Company AS FromCompany,
		@IsRecipient AS IsRecipient,
		@IsArchived AS IsArchived,
		dbo.MBX_ToNames(m.MessageID) AS ToNames
	FROM MBX_Message m
	JOIN Users u ON u.UID = m.FromUID
	JOIN Companies c ON c.CID = m.FromCID
	WHERE m.MessageID = @MessageID AND m.IsDeleted = 0

	SELECT mi.MessageItemID, mi.ItemType, mi.ItemID, mi.ItemLabel, mi.FormID,
		t.TaskID, t.TaskType, t.Status AS TaskStatus, t.DueDate,
		CASE WHEN t.AssignedToUID = @UID THEN 1 ELSE 0 END AS IsMyTask
	FROM MBX_MessageItem mi
	LEFT JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
	WHERE mi.MessageID = @MessageID
END
GO

-- Same as 004's version, except a task item that hasn't been started yet (ItemID '0')
-- isn't carried onto the reply.
CREATE OR ALTER PROCEDURE [dbo].[MBX_SendReply]
	@UID INT,
	@ReplyToMessageID INT,
	@Subject NVARCHAR(255),
	@Body NVARCHAR(MAX) = NULL
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF NOT EXISTS (
		SELECT 1 FROM MBX_Message WHERE MessageID = @ReplyToMessageID AND (FromUID = @UID OR EXISTS (
			SELECT 1 FROM MBX_Recipient WHERE MessageID = @ReplyToMessageID AND ToUID = @UID
		))
	)
	BEGIN
		RETURN
	END

	DECLARE @FromCID INT = dbo.mycid(@UID)
	DECLARE @NewMessageID INT

	INSERT INTO MBX_Message (FromUID, FromCID, Subject, Body, ReplyToMessageID)
	SELECT @UID, @FromCID, @Subject, @Body, @ReplyToMessageID

	SELECT @NewMessageID = SCOPE_IDENTITY()

	;WITH participants AS (
		SELECT FromUID AS UID FROM MBX_Message WHERE MessageID = @ReplyToMessageID
		UNION
		SELECT ToUID FROM MBX_Recipient WHERE MessageID = @ReplyToMessageID
	)
	INSERT INTO MBX_Recipient (MessageID, ToUID, ToCID)
	SELECT @NewMessageID, u.UID, u.CID
	FROM participants p
	JOIN Users u ON u.UID = p.UID AND u.Active = 1
	WHERE p.UID <> @UID

	-- Carry forward the Form Application record(s), if any, from the message being
	-- replied to. This is a NEW MBX_MessageItem row on the reply (not a shared
	-- reference to the old one) — access is still independently re-verified at open
	-- time regardless, same as any other item, so duplicating the pointer costs
	-- nothing security-wise and keeps each message's item list self-contained.
	INSERT INTO MBX_MessageItem (MessageID, ItemType, ItemID, ItemLabel, OwnerCID, FormID)
	SELECT @NewMessageID, mi.ItemType, mi.ItemID, mi.ItemLabel, mi.OwnerCID, mi.FormID
	FROM MBX_MessageItem mi
	WHERE mi.MessageID = @ReplyToMessageID AND mi.ItemType = 'IAFormRecord' AND mi.ItemID <> '0'

	SELECT @NewMessageID AS MessageID
END
GO
