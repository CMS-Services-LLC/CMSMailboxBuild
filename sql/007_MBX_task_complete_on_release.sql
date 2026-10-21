/*
	A FormApplication task now counts as Completed only once its record is released
	("Save for Use"), not on the first save. Requires 006.

	Why: an unreleased record is visible only to the company that created it
	(NEO_IAUpdateRecordACS adds upstream companies on release), so the assigner can't
	open it until then. Showing the task as Completed before that was misleading.

	- MBX_LinkFormTask: new. Replaces MBX_CompleteFormTask. On the assignee's first
	  save it links the new record to the task's item (ItemID '0' -> MainID) and records
	  it as the task's ResultID, but leaves the task Open.
	- MBX_CompleteFormTask: dropped (only CMSMailbox's IaViewerController called it).
	- MBX_GetMessage: TaskStatus is now derived for FormApplication tasks:
	    Open      - no record yet
	    Saved     - record saved, not yet released
	    Completed - record released (wherever it was released: CMSMailbox or CMSNEO)
	  plus a new TaskCompleted column (the record's DTReleased). Deriving it at read
	  time means a release done directly in CMSNEO counts too, with no hook needed.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Same validation as 006's MBX_CompleteFormTask: the task must still be open and
-- unstarted for this caller, and the record must be an active record of the task's
-- form that this caller created.
CREATE OR ALTER PROCEDURE [dbo].[MBX_LinkFormTask]
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
		SELECT 'no unstarted form task for this item and user' AS err
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

	UPDATE MBX_Task SET ResultID = CAST(@MainID AS NVARCHAR(100))
	WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID, @MainID AS MainID
END
GO

IF OBJECT_ID('dbo.MBX_CompleteFormTask', 'P') IS NOT NULL
	DROP PROCEDURE [dbo].[MBX_CompleteFormTask]
GO

-- Same as 006's version, except TaskStatus is derived for FormApplication tasks (see
-- the header) and TaskCompleted is added.
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
		t.TaskID, t.TaskType,
		CASE
			WHEN t.TaskType <> 'FormApplication' THEN t.Status
			WHEN t.Status = 'Cancelled' THEN 'Cancelled'
			WHEN rel.DTReleased IS NOT NULL THEN 'Completed'
			WHEN t.ResultID IS NOT NULL THEN 'Saved'
			ELSE 'Open'
		END AS TaskStatus,
		CASE WHEN t.TaskType = 'FormApplication' THEN rel.DTReleased ELSE t.DTCompleted END AS TaskCompleted,
		t.DueDate,
		CASE WHEN t.AssignedToUID = @UID THEN 1 ELSE 0 END AS IsMyTask
	FROM MBX_MessageItem mi
	LEFT JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
	OUTER APPLY (
		SELECT TOP 1 fr.DTReleased
		FROM NEO_IAFormRecords xfr
		JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.active = 1
		WHERE t.TaskType = 'FormApplication' AND xfr.ID = TRY_CAST(t.ResultID AS INT)
	) rel
	WHERE mi.MessageID = @MessageID
END
GO
