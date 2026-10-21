/*
	Optional review step for tasks. Requires 006-008.

	When the tasks are sent, the assigner chooses either of these:
	  - no review (the default, and how it worked before): a task is Completed as soon
	    as the assignee finishes it, or
	  - "Require my review": a finished task shows "Pending Review" until the assigner
	    marks it Completed (in CMSMailbox's Sent folder).

	"Finished" means: FormApplication = its record has been released (Save for Use);
	DynamicReport = the report has been uploaded (Status 'Completed', set by
	MBX_CompleteDRTask). Pending Review is derived at read time, the same way 007
	derives form task status, so no stored status needs to change for it.

	- MBX_Task: RequiresReview, ReviewedByUID, DTReviewed.
	- MBX_TaskIsDone: new. One definition of "finished", shared by the procs below.
	- MBX_CreateTask: takes @RequiresReview (default 0).
	- MBX_ReviewTask: new. The assigner marks a finished task Completed.
	- MBX_GetMessage: TaskStatus can now be 'Pending Review'; adds IsAssigner and
	  RequiresReview.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF COL_LENGTH('dbo.MBX_Task', 'RequiresReview') IS NULL
	ALTER TABLE [dbo].[MBX_Task] ADD [RequiresReview] [bit] NOT NULL CONSTRAINT [DF_MBX_Task_RequiresReview] DEFAULT (0)
GO
IF COL_LENGTH('dbo.MBX_Task', 'ReviewedByUID') IS NULL
	ALTER TABLE [dbo].[MBX_Task] ADD [ReviewedByUID] [int] NULL
GO
IF COL_LENGTH('dbo.MBX_Task', 'DTReviewed') IS NULL
	ALTER TABLE [dbo].[MBX_Task] ADD [DTReviewed] [datetime] NULL
GO

-- 1 when the assignee has finished the task (see the header), else 0.
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskIsDone](@TaskID INT)
RETURNS BIT
AS
BEGIN
	DECLARE @done BIT = 0

	SELECT @done = 1
	FROM MBX_Task t
	WHERE t.TaskID = @TaskID
	AND t.Status <> 'Cancelled'
	AND (
		(t.TaskType = 'DynamicReport' AND t.Status = 'Completed')
		OR (t.TaskType = 'FormApplication' AND EXISTS (
			SELECT 1
			FROM NEO_IAFormRecords xfr
			JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.active = 1
			WHERE xfr.ID = TRY_CAST(t.ResultID AS INT) AND fr.DTReleased IS NOT NULL
		))
	)

	RETURN @done
END
GO

-- Same as 008's version plus @RequiresReview.
CREATE OR ALTER PROCEDURE [dbo].[MBX_CreateTask]
	@UID INT,
	@MessageItemID INT,
	@TaskType VARCHAR(20),
	@AssignedToUID INT,
	@FormID VARCHAR(100) = NULL,
	@DueDate VARCHAR(20) = NULL,
	@ReportName NVARCHAR(255) = NULL,
	@ReportType NVARCHAR(100) = NULL,
	@TemplateFileName NVARCHAR(255) = NULL,
	@TemplateHeaders NVARCHAR(MAX) = NULL,
	@TemplateBytes VARBINARY(MAX) = NULL,
	@RequiresReview BIT = 0
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

	INSERT INTO MBX_Task (MessageItemID, TaskType, AssignedByUID, AssignedToUID, FormID, DueDate,
		ReportName, ReportType, TemplateFileName, TemplateHeaders, TemplateBytes, RequiresReview)
	SELECT @MessageItemID, @TaskType, @UID, @AssignedToUID, NULLIF(@FormID, ''), TRY_CONVERT(date, NULLIF(@DueDate, '')),
		NULLIF(@ReportName, ''), NULLIF(@ReportType, ''), NULLIF(@TemplateFileName, ''), NULLIF(@TemplateHeaders, ''), @TemplateBytes,
		ISNULL(@RequiresReview, 0)

	SELECT SCOPE_IDENTITY() AS TaskID
END
GO

-- The assigner marks a finished, review-required task Completed. Only the task's own
-- assigner, only once, and only after the assignee has finished it.
CREATE OR ALTER PROCEDURE [dbo].[MBX_ReviewTask]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @TaskID INT

	SELECT @TaskID = TaskID
	FROM MBX_Task
	WHERE MessageItemID = @MessageItemID
	AND AssignedByUID = @UID
	AND RequiresReview = 1
	AND DTReviewed IS NULL

	IF @TaskID IS NULL
	BEGIN
		SELECT 'no task awaiting your review on this item' AS err
		RETURN
	END

	IF dbo.MBX_TaskIsDone(@TaskID) = 0
	BEGIN
		SELECT 'the assignee has not finished this task yet' AS err
		RETURN
	END

	UPDATE MBX_Task SET ReviewedByUID = @UID, DTReviewed = getdate() WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID
END
GO

-- Same as 007's version, except TaskStatus is now:
--   not finished: FormApplication -> Open / Saved (as in 007); other types -> stored Status
--   finished:     'Pending Review' if RequiresReview and not yet reviewed, else 'Completed'
-- plus IsAssigner and RequiresReview. TaskCompleted = when it became Completed.
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
			WHEN t.TaskID IS NULL THEN NULL
			WHEN t.Status = 'Cancelled' THEN 'Cancelled'
			WHEN d.Done = 1 AND t.RequiresReview = 1 AND t.DTReviewed IS NULL THEN 'Pending Review'
			WHEN d.Done = 1 THEN 'Completed'
			WHEN t.TaskType = 'FormApplication' AND t.ResultID IS NOT NULL THEN 'Saved'
			WHEN t.TaskType = 'FormApplication' THEN 'Open'
			ELSE t.Status
		END AS TaskStatus,
		CASE
			WHEN d.Done = 0 THEN NULL
			WHEN t.RequiresReview = 1 THEN t.DTReviewed
			WHEN t.TaskType = 'FormApplication' THEN rel.DTReleased
			ELSE t.DTCompleted
		END AS TaskCompleted,
		t.DueDate,
		t.RequiresReview,
		CASE WHEN t.AssignedToUID = @UID THEN 1 ELSE 0 END AS IsMyTask,
		CASE WHEN t.AssignedByUID = @UID THEN 1 ELSE 0 END AS IsAssigner
	FROM MBX_MessageItem mi
	LEFT JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
	OUTER APPLY (SELECT dbo.MBX_TaskIsDone(t.TaskID) AS Done) d
	OUTER APPLY (
		SELECT TOP 1 fr.DTReleased
		FROM NEO_IAFormRecords xfr
		JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.active = 1
		WHERE t.TaskType = 'FormApplication' AND xfr.ID = TRY_CAST(t.ResultID AS INT)
	) rel
	WHERE mi.MessageID = @MessageID
END
GO
