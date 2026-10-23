/*
	Task tracking (Phase 4): the assigned-tasks list in CMS. Requires 006-020.

	- MBX_Task: adds DTCancelled/CancelledByUID (a task can now be cancelled) and
	  DTLastReminder/ReminderCount (reminder emails sent by the assigner).
	- MBX_GetAssignedTasks: the list. @Scope 'mine' = tasks the caller assigned (any of
	  their accounts by email, like MBX_IsTaskAssigner); 'company' = every task assigned
	  by anyone in the caller's own company. IsMine marks the rows the caller may act on.
	- MBX_CancelTask: the assigner cancels a task that isn't Completed or already
	  Cancelled. The mailbox viewers already refuse work on a Cancelled task
	  (MBX_GetOpenFormTask and MBX_CompleteDRTask need Status 'Open'; MBX_GetExamAccess
	  blocks writes), and MBX_TaskStatusText reports it as 'Cancelled'.
	- MBX_RemindTask: the assigner asks for a reminder email to the assignee, at most
	  one an hour per task. Returns what CMS needs to send it; CMS sends the email.
	- MBX_CreateHandoffCode: also issues a code for the message's AUTHOR (by email),
	  so the assigner can open their own sent message from the CMS task list.

	Not reachable from CMS's browser dispatcher (that only runs NEO* and a_Suite_*
	procs); CMS calls these from MailboxShareController with the caller's validated UID.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF COL_LENGTH('dbo.MBX_Task', 'DTCancelled') IS NULL
	ALTER TABLE [dbo].[MBX_Task] ADD [DTCancelled] [datetime] NULL
GO
IF COL_LENGTH('dbo.MBX_Task', 'CancelledByUID') IS NULL
	ALTER TABLE [dbo].[MBX_Task] ADD [CancelledByUID] [int] NULL
GO
IF COL_LENGTH('dbo.MBX_Task', 'DTLastReminder') IS NULL
	ALTER TABLE [dbo].[MBX_Task] ADD [DTLastReminder] [datetime] NULL
GO
IF COL_LENGTH('dbo.MBX_Task', 'ReminderCount') IS NULL
	ALTER TABLE [dbo].[MBX_Task] ADD [ReminderCount] [int] NOT NULL CONSTRAINT [DF_MBX_Task_ReminderCount] DEFAULT (0)
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetAssignedTasks]
	@UID INT,
	@Scope VARCHAR(20) = 'mine'
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MyCID INT = dbo.mycid(@UID)

	SELECT x.*,
		CAST(CASE WHEN x.DueDate < CAST(getdate() AS date) AND x.TaskStatus NOT IN ('Completed', 'Cancelled', 'Pending Review') THEN 1 ELSE 0 END AS BIT) AS IsOverdue
	FROM (
		SELECT t.TaskID, mi.MessageID, t.MessageItemID, m.Subject,
			t.TaskType, mi.ItemLabel AS TaskName,
			ab.Fname + ' ' + ab.Lname AS AssignedByName,
			at.Fname + ' ' + at.Lname AS AssignedToName,
			atc.Company AS AssignedToCompany,
			t.DTCreated, t.DueDate,
			dbo.MBX_TaskStatusText(t.TaskID) AS TaskStatus,
			t.RequiresReview, t.DTReviewed, t.DTCompleted, t.DTCancelled,
			t.ReminderCount, t.DTLastReminder,
			dbo.MBX_IsTaskAssigner(t.TaskID, @UID) AS IsMine
		FROM MBX_Task t
		JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
		JOIN MBX_Message m ON m.MessageID = mi.MessageID AND m.IsDeleted = 0
		JOIN Users ab ON ab.UID = t.AssignedByUID
		JOIN Users at ON at.UID = t.AssignedToUID
		LEFT JOIN Companies atc ON atc.CID = dbo.mycid(t.AssignedToUID)
		WHERE (
			(@Scope = 'company' AND dbo.mycid(t.AssignedByUID) = @MyCID)
			OR dbo.MBX_IsTaskAssigner(t.TaskID, @UID) = 1
		)
	) x
	ORDER BY x.DTCreated DESC, x.TaskID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_CancelTask]
	@UID INT,
	@TaskID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF dbo.MBX_IsTaskAssigner(@TaskID, @UID) = 0
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	IF dbo.MBX_TaskStatusText(@TaskID) IN ('Completed', 'Cancelled')
	BEGIN
		SELECT 'not_cancellable' AS err
		RETURN
	END

	UPDATE MBX_Task SET Status = 'Cancelled', DTCancelled = getdate(), CancelledByUID = @UID
	WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_RemindTask]
	@UID INT,
	@TaskID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF dbo.MBX_IsTaskAssigner(@TaskID, @UID) = 0
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	IF dbo.MBX_TaskStatusText(@TaskID) IN ('Completed', 'Cancelled')
	BEGIN
		SELECT 'not_remindable' AS err
		RETURN
	END

	IF EXISTS (SELECT 1 FROM MBX_Task WHERE TaskID = @TaskID AND DTLastReminder > DATEADD(HOUR, -1, getdate()))
	BEGIN
		SELECT 'too_soon' AS err
		RETURN
	END

	UPDATE MBX_Task SET DTLastReminder = getdate(), ReminderCount = ReminderCount + 1
	WHERE TaskID = @TaskID

	SELECT t.TaskID, mi.MessageID, mi.ItemLabel AS TaskName, t.DueDate,
		at.Email AS AssigneeEmail, at.Active AS AssigneeActive,
		me.Fname + ' ' + me.Lname AS SenderName, mc.Company AS SenderCompany
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	JOIN Users at ON at.UID = t.AssignedToUID
	JOIN Users me ON me.UID = @UID
	LEFT JOIN Companies mc ON mc.CID = dbo.mycid(@UID)
	WHERE t.TaskID = @TaskID
END
GO

-- @UID is the CMSNEO caller (from their validated JWT); @Code comes from a
-- cryptographic RNG in CMSNEO. The code is issued for the caller's own account on
-- @MessageID: a recipient account with the caller's email, or else (sql/021) the
-- message's author account with the caller's email. Returns nothing if the caller has
-- no account on that message.
CREATE OR ALTER PROCEDURE [dbo].[MBX_CreateHandoffCode]
	@UID INT,
	@MessageID INT,
	@Code VARCHAR(64)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MailboxUID INT

	SELECT TOP 1 @MailboxUID = r.ToUID
	FROM MBX_Recipient r
	JOIN Users ru ON ru.UID = r.ToUID AND ru.Active = 1
	JOIN Users me ON me.UID = @UID AND me.Active = 1
	WHERE r.MessageID = @MessageID
	AND ru.Email = me.Email
	ORDER BY CASE WHEN r.ToUID = @UID THEN 0 ELSE 1 END

	IF @MailboxUID IS NULL
		SELECT @MailboxUID = m.FromUID
		FROM MBX_Message m
		JOIN Users au ON au.UID = m.FromUID AND au.Active = 1
		JOIN Users me ON me.UID = @UID AND me.Active = 1
		WHERE m.MessageID = @MessageID
		AND m.IsDeleted = 0
		AND au.Email = me.Email

	IF @MailboxUID IS NULL RETURN

	-- Housekeeping: codes are worthless after a minute.
	DELETE FROM MBX_HandoffCode WHERE DTExpires < DATEADD(DAY, -1, getdate())

	INSERT INTO MBX_HandoffCode (Code, UID, MessageID, CreatedByUID, DTExpires)
	SELECT @Code, @MailboxUID, @MessageID, @UID, DATEADD(SECOND, 60, getdate())

	SELECT @Code AS Code, @MessageID AS MessageID
END
GO
