/*
	Exams on replies, with the assigner's management view. Requires 019.

	- Replies carry the exam: MBX_SendReply copies an ExamTask item (and an existing
	  copy) onto the reply as ItemType 'ExamRef', ItemID = the ORIGINAL ExamTask's
	  MessageItemID. There's no task on the copy; the original task stays the one
	  source of status.
	- MBX_GetExamAccess replaces 019's MBX_GetExamTask as the exam viewer's gate, and
	  works for the original item or a copy. Role:
	    'Assignee' (the task's assignee, any of their accounts by email): the examined
	        company's own view; writes until the task is Completed;
	    'Assigner' (the task's assigner, by email): the management view (scoring,
	        audit layers); writes unless the task is Cancelled.
	  Both still need: the caller is a recipient OR the author of the message the item
	  is on, the caller's company tree reaches the examined company (AccessTreeDown,
	  Down = 1), and the exam is still active and shared with that company.
	- MBX_GetMessage: same as 015's version, plus an ExamRef copy shows its original
	  task's status (and Mark as Completed for the assigner while it's Pending Review).

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER TABLE [dbo].[MBX_MessageItem] DROP CONSTRAINT [CK_MBX_MessageItem_ItemType]
GO
ALTER TABLE [dbo].[MBX_MessageItem] WITH CHECK ADD CONSTRAINT [CK_MBX_MessageItem_ItemType]
CHECK ([ItemType] IN ('File','FollowupAttachment','IAField','DRField','ExamFile','IAFormRecord','DRTask','DynamicReport','ExamTask','ExamRef'))
GO
ALTER TABLE [dbo].[MBX_MessageItem] CHECK CONSTRAINT [CK_MBX_MessageItem_ItemType]
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetExamAccess]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @OriginItemID INT, @MessageID INT

	SELECT @MessageID = mi.MessageID,
		@OriginItemID = CASE mi.ItemType
			WHEN 'ExamTask' THEN mi.MessageItemID
			WHEN 'ExamRef' THEN TRY_CAST(mi.ItemID AS INT)
		END
	FROM MBX_MessageItem mi
	WHERE mi.MessageItemID = @MessageItemID AND mi.ItemType IN ('ExamTask', 'ExamRef')

	IF @OriginItemID IS NULL RETURN

	-- Recipient or author of the message this item (original or copy) is on.
	IF NOT EXISTS (
		SELECT 1 FROM MBX_Message m
		WHERE m.MessageID = @MessageID
		AND (m.FromUID = @UID OR EXISTS (SELECT 1 FROM MBX_Recipient r WHERE r.MessageID = m.MessageID AND r.ToUID = @UID))
	)
		RETURN

	SELECT x.*,
		CAST(CASE
			WHEN x.TaskStatus = 'Cancelled' THEN 0
			WHEN x.Role = 'Assignee' AND x.TaskStatus = 'Completed' THEN 0
			ELSE 1 END AS BIT) AS CanWrite
	FROM (
		SELECT t.TaskID, t.MessageItemID AS OriginItemID, t.ExamID, t.ExamCID,
			n.Name AS ExamName, c.Company AS ExamCompany,
			dbo.MBX_TaskStatusText(t.TaskID) AS TaskStatus,
			CASE
				WHEN dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1 THEN 'Assignee'
				WHEN dbo.MBX_IsTaskAssigner(t.TaskID, @UID) = 1 THEN 'Assigner'
			END AS Role
		FROM MBX_Task t
		JOIN MBX_MessageItem omi ON omi.MessageItemID = t.MessageItemID AND omi.ItemType = 'ExamTask'
		JOIN a_aMgtExamNames n ON n.ExamID = t.ExamID AND n.Active = 1
		JOIN a_aMgtExamShare s ON s.ExamID = t.ExamID AND s.xCID = t.ExamCID AND s.Active = 1 AND s.Shared = 1
		JOIN AccessTreeDown(@UID) atd ON atd.CID = t.ExamCID AND atd.Down = 1
		JOIN Companies c ON c.CID = t.ExamCID
		WHERE t.MessageItemID = @OriginItemID AND t.TaskType = 'Exam'
	) x
	WHERE x.Role IS NOT NULL
END
GO

-- Same as 010's version, plus exams: an ExamTask item becomes an 'ExamRef' copy
-- pointing at it (ItemID = its MessageItemID); an existing ExamRef is copied as-is.
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

	-- Carry forward Form Application records, completed Dynamic Reports, and exams
	-- from the message being replied to. These are NEW MBX_MessageItem rows on the
	-- reply; access is still independently re-verified at open time, as for any item.
	INSERT INTO MBX_MessageItem (MessageID, ItemType, ItemID, ItemLabel, OwnerCID, FormID)
	SELECT @NewMessageID,
		CASE mi.ItemType WHEN 'DRTask' THEN 'DynamicReport' WHEN 'ExamTask' THEN 'ExamRef' ELSE mi.ItemType END,
		CASE WHEN mi.ItemType = 'ExamTask' THEN CAST(mi.MessageItemID AS NVARCHAR(50)) ELSE mi.ItemID END,
		mi.ItemLabel, mi.OwnerCID, mi.FormID
	FROM MBX_MessageItem mi
	WHERE mi.MessageID = @ReplyToMessageID
	AND (
		(mi.ItemType IN ('IAFormRecord', 'DRTask', 'DynamicReport') AND mi.ItemID <> '0')
		OR mi.ItemType IN ('ExamTask', 'ExamRef')
	)

	SELECT @NewMessageID AS MessageID
END
GO

-- Same as 015's version, plus: an ExamRef copy reports its original exam task.
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
		dbo.MBX_TaskStatusText(t.TaskID) AS TaskStatus,
		CASE
			WHEN d.Done = 0 THEN NULL
			WHEN t.RequiresReview = 1 THEN t.DTReviewed
			WHEN t.TaskType = 'FormApplication' THEN rel.DTReleased
			ELSE t.DTCompleted
		END AS TaskCompleted,
		t.DueDate,
		t.RequiresReview,
		CASE WHEN t.AssignedToUID = @UID THEN 1 ELSE 0 END AS IsMyTask,
		CASE WHEN t.TaskID IS NOT NULL THEN dbo.MBX_IsTaskAssigner(t.TaskID, @UID) ELSE 0 END AS IsAssigner,
		ot.OriginTaskType,
		ot.OriginTaskStatus,
		ot.OriginDueDate,
		CASE WHEN ot.OriginTaskStatus = 'Pending Review' AND ot.CallerIsAssigner = 1 THEN ot.OriginTaskItemID END AS ReviewTaskItemID
	FROM MBX_MessageItem mi
	LEFT JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
	OUTER APPLY (SELECT dbo.MBX_TaskIsDone(t.TaskID) AS Done) d
	OUTER APPLY (
		SELECT TOP 1 fr.DTReleased
		FROM NEO_IAFormRecords xfr
		JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.active = 1
		WHERE t.TaskType = 'FormApplication' AND xfr.ID = TRY_CAST(t.ResultID AS INT)
	) rel
	-- A reply's copy of a task's record/report/exam: the task it came from, if the
	-- caller is that task's assignee or assigner.
	OUTER APPLY (
		SELECT TOP 1
			rt.MessageItemID AS OriginTaskItemID,
			rt.TaskType AS OriginTaskType,
			dbo.MBX_TaskStatusText(rt.TaskID) AS OriginTaskStatus,
			rt.DueDate AS OriginDueDate,
			dbo.MBX_IsTaskAssigner(rt.TaskID, @UID) AS CallerIsAssigner
		FROM MBX_Task rt
		WHERE t.TaskID IS NULL
		AND mi.ItemID <> '0'
		AND (
			(mi.ItemType = 'ExamRef' AND rt.TaskType = 'Exam' AND rt.MessageItemID = TRY_CAST(mi.ItemID AS INT))
			OR (rt.ResultID = mi.ItemID
				AND rt.TaskType = CASE mi.ItemType WHEN 'IAFormRecord' THEN 'FormApplication' WHEN 'DynamicReport' THEN 'DynamicReport' END)
		)
		AND (dbo.MBX_IsTaskAssigner(rt.TaskID, @UID) = 1 OR dbo.MBX_IsTaskAssignee(rt.TaskID, @UID) = 1)
		ORDER BY rt.TaskID DESC
	) ot
	WHERE mi.MessageID = @MessageID
END
GO
