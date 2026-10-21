/*
	Dynamic Report tasks (Phase 2 of WizardAssignments_Plan.md). Requires 006 + 007.

	The assigner uploads an Excel template in CMSNEO (Assign a Task → Dynamic Report).
	CMSNEO reads the template's column headers with GemBox and stores the file plus
	its headers on the task. The assignee downloads the template from CMSMailbox, fills
	it in, and uploads it back. CMSMailbox passes the file to CMSNEO's
	main/MailboxDRTaskSubmit. That endpoint parses it the same way a normal Dynamic
	Report upload is parsed, requires the template's headers, inserts the report as the
	assignee (NEO_InsertDynamicReportLines_Bulk + NEO_InsertDynamicReports_v3), and
	completes the task. The task's item is ItemType 'DRTask' with ItemID '0' until then,
	and the new ReportID afterwards.

	Like the other task types, assigning grants nothing: assignees must already have
	the Dynamic Reports permission (user group 'Dynamic Reports' or Global Admin),
	re-checked by CMSNEO when the report is submitted.

	- MBX_MessageItem.ItemType: allows 'DRTask'.
	- MBX_CreateTask: also takes ReportName/ReportType/TemplateFileName/TemplateHeaders/
	  TemplateBytes. Existing FormApplication callers are unaffected (new params default
	  to NULL).
	- MBX_GetDRTask: the task for an item, for its assignee only (template download +
	  submit).
	- MBX_CompleteDRTask: links the new ReportID and completes the task.
	- MBX_GetDRTaskCandidates: recipient picker.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER TABLE [dbo].[MBX_MessageItem] DROP CONSTRAINT [CK_MBX_MessageItem_ItemType]
GO
ALTER TABLE [dbo].[MBX_MessageItem] WITH CHECK ADD CONSTRAINT [CK_MBX_MessageItem_ItemType]
CHECK ([ItemType] IN ('File','FollowupAttachment','IAField','DRField','ExamFile','IAFormRecord','DRTask'))
GO
ALTER TABLE [dbo].[MBX_MessageItem] CHECK CONSTRAINT [CK_MBX_MessageItem_ItemType]
GO

-- Same as 006's version plus the Dynamic Report columns. Only the message's own author
-- can attach a task to one of its items, and only for a recipient of that message.
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
	@TemplateBytes VARBINARY(MAX) = NULL
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
		ReportName, ReportType, TemplateFileName, TemplateHeaders, TemplateBytes)
	SELECT @MessageItemID, @TaskType, @UID, @AssignedToUID, NULLIF(@FormID, ''), TRY_CONVERT(date, NULLIF(@DueDate, '')),
		NULLIF(@ReportName, ''), NULLIF(@ReportType, ''), NULLIF(@TemplateFileName, ''), NULLIF(@TemplateHeaders, ''), @TemplateBytes

	SELECT SCOPE_IDENTITY() AS TaskID
END
GO

-- The Dynamic Report task on an item, returned only to its assignee, who must also be
-- a recipient of the item's message. Any status, so the template stays downloadable;
-- callers that submit check Status = 'Open' themselves.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRTask]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT t.TaskID, t.Status, t.ReportName, t.ReportType, t.TemplateFileName, t.TemplateHeaders, t.TemplateBytes, t.ResultID
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	JOIN MBX_Recipient r ON r.MessageID = mi.MessageID AND r.ToUID = @UID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'DynamicReport'
	AND t.AssignedToUID = @UID
	AND mi.ItemType = 'DRTask'
END
GO

-- Called by CMSNEO after it has inserted the report as @UID. Re-validates that the
-- task is still open for this caller and that the report exists and was created by
-- this caller.
CREATE OR ALTER PROCEDURE [dbo].[MBX_CompleteDRTask]
	@UID INT,
	@MessageItemID INT,
	@ReportID VARCHAR(100)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @TaskID INT

	SELECT @TaskID = t.TaskID
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'DynamicReport'
	AND t.Status = 'Open'
	AND t.AssignedToUID = @UID
	AND mi.ItemID = '0'

	IF @TaskID IS NULL
	BEGIN
		SELECT 'no open dynamic report task for this item and user' AS err
		RETURN
	END

	IF NOT EXISTS (SELECT 1 FROM NEO_DynamicReports WHERE ReportID = @ReportID AND CreatedBy = @UID)
	BEGIN
		SELECT 'report not found for this user' AS err
		RETURN
	END

	UPDATE MBX_MessageItem SET ItemID = CAST(@ReportID AS NVARCHAR(50))
	WHERE MessageItemID = @MessageItemID

	UPDATE MBX_Task SET Status = 'Completed', ResultID = @ReportID, DTCompleted = getdate()
	WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID, @ReportID AS ReportID
END
GO

-- Recipient picker for a Dynamic Report task: people in the caller's network who hold
-- the 'Dynamic Reports' user-group permission or are Global Admins, deduped to each
-- person's real MGT account (same pattern as NEO_IAGetRecipients).
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRTaskCandidates]
	@UID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT DISTINCT u.MgtUID AS UID, u.Name, u.Email, u.Company
	FROM neousers(@UID) u
	JOIN NEO_SecurityGroupAssignments sga ON sga.uid = u.MgtUID AND sga.active = 1
	JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action IN ('Dynamic Reports', 'Global Administrator')
	WHERE u.MgtUID <> @UID
	ORDER BY u.Name
END
GO
